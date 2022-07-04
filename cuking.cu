#include <absl/base/thread_annotations.h>
#include <absl/container/flat_hash_map.h>
#include <absl/flags/flag.h>
#include <absl/flags/parse.h>
#include <absl/synchronization/blocking_counter.h>
#include <absl/synchronization/mutex.h>
#include <absl/time/time.h>

#include <algorithm>
#include <iostream>
#include <memory>
#include <nlohmann/json.hpp>
#include <string>
#include <vector>

#include "gcs_client.h"
#include "thread_pool.h"

ABSL_FLAG(std::string, sample_map, "",
          "A JSON file mapping sample IDs to cuking input paths, e.g. "
          "gs://some/bucket/sample_map.json");
ABSL_FLAG(std::string, output, "",
          "The sparse matrix result JSON output path, e.g. "
          "gs://some/bucket/relatedness.json");
ABSL_FLAG(
    uint32_t, max_results, 100 << 20,
    "How many coefficients for related sample pairs to reserve memory for.");
ABSL_FLAG(int, num_reader_threads, 100,
          "How many threads to use for parallel file reading.");
ABSL_FLAG(
    float, king_coeff_threshold, 0.0442f,
    "Only store coefficients larger than this threshold. Defaults to 3rd "
    "degree or closer (see https://www.kingrelatedness.com/manual.shtml).");

namespace {

// Custom deleter for RAII-style CUDA-managed array.
template <typename T>
struct CudaArrayDeleter {
  void operator()(T *const val) const { cudaFree(val); }
};

template <typename T>
using CudaArray = std::unique_ptr<T[], CudaArrayDeleter<T>>;

template <typename T>
CudaArray<T> NewCudaArray(const size_t size) {
  static_assert(std::is_pod<T>::value, "A must be a POD type.");
  T *buffer = nullptr;
  const auto err = cudaMallocManaged(&buffer, size * sizeof(T));
  if (err) {
    std::cerr << "Error: can't allocate CUDA memory: "
              << cudaGetErrorString(err) << std::endl;
    exit(1);
  }
  return CudaArray<T>(buffer, CudaArrayDeleter<T>());
}

struct ReadSamplesResult {
  uint32_t num_entries = 0;
  CudaArray<uint64_t> bit_sets;
};

// Reads and decompresses sample data from `paths`.
std::optional<ReadSamplesResult> ReadSamples(
    const std::vector<std::string> &paths,
    cuking::GcsClient *const gcs_client) {
  cuking::ThreadPool thread_pool(absl::GetFlag(FLAGS_num_reader_threads));
  absl::BlockingCounter blocking_counter(paths.size());
  absl::Mutex mutex;
  ReadSamplesResult result ABSL_GUARDED_BY(mutex);
  std::atomic<bool> success(true);
  for (size_t i = 0; i < paths.size(); ++i) {
    thread_pool.Schedule([&, i] {
      const auto &path = paths[i];

      auto content = gcs_client->Read(path);
      if (!content.ok()) {
        std::cerr << "Error: failed to read \"" << path
                  << "\": " << content.status() << std::endl;
        success = false;
        blocking_counter.DecrementCount();
        return;
      }

      // Make sure the buffer is set and expected sizes match.
      const size_t num_entries = content->size() / sizeof(uint64_t) / 2;
      {
        const absl::MutexLock lock(&mutex);
        if (result.num_entries == 0) {
          result.num_entries = num_entries;
          result.bit_sets =
              NewCudaArray<uint64_t>(num_entries * 2 * paths.size());
        } else if (result.num_entries != num_entries) {
          std::cerr << "Mismatch for number of entries encountered for \""
                    << path << "\": " << num_entries << " vs "
                    << result.num_entries << "." << std::endl;
          success = false;
          blocking_counter.DecrementCount();
          return;
        }
      }

      // Copy to the destination buffer.
      memcpy(
          reinterpret_cast<char *>(result.bit_sets.get() + i * 2 * num_entries),
          content->data(), content->size());

      blocking_counter.DecrementCount();
    });
  }

  blocking_counter.Wait();
  return success ? std::move(result) : std::optional<ReadSamplesResult>();
}

__device__ float ComputeKing(const uint32_t num_entries,
                             const uint64_t *const het_i_entries,
                             const uint64_t *const hom_alt_i_entries,
                             const uint64_t *const het_j_entries,
                             const uint64_t *const hom_alt_j_entries) {
  // See https://hail.is/docs/0.2/methods/relatedness.html#hail.methods.king.
  uint32_t num_het_i = 0, num_het_j = 0, num_both_het = 0, num_opposing_hom = 0;
  for (uint32_t k = 0; k < num_entries; ++k) {
    const uint64_t het_i = het_i_entries[k];
    const uint64_t hom_alt_i = hom_alt_i_entries[k];
    const uint64_t het_j = het_j_entries[k];
    const uint64_t hom_alt_j = hom_alt_j_entries[k];
    const uint64_t hom_ref_i = (~het_i) & (~hom_alt_i);
    const uint64_t hom_ref_j = (~het_j) & (~hom_alt_j);
    const uint64_t missing_mask_i = ~(het_i & hom_alt_i);
    const uint64_t missing_mask_j = ~(het_j & hom_alt_j);
    const uint64_t missing_mask = missing_mask_i & missing_mask_j;
    num_het_i += __popcll(het_i & missing_mask_i);
    num_het_j += __popcll(het_j & missing_mask_j);
    num_both_het += __popcll(het_i & het_j & missing_mask);
    num_opposing_hom += __popcll(
        ((hom_ref_i & hom_alt_j) | (hom_ref_j & hom_alt_i)) & missing_mask);
  }

  // Return the "between-family" estimator.
  const uint32_t min_hets = num_het_i < num_het_j ? num_het_i : num_het_j;
  return 0.5f +
         (2.f * num_both_het - 4.f * num_opposing_hom - num_het_i - num_het_j) /
             (4.f * min_hets);
}

// Stores the KING coefficient for one pair of samples.
struct KingResult {
  uint32_t sample_i, sample_j;
  float coeff;
};

__global__ void ComputeKingKernel(const uint32_t num_samples,
                                  const uint32_t num_entries,
                                  const uint64_t *const bit_sets,
                                  const float coeff_threshold,
                                  const uint32_t max_results,
                                  KingResult *const results,
                                  uint32_t *const result_index) {
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  const int i = index / num_samples;
  const int j = index % num_samples;
  if (i >= num_samples || i >= j) {
    return;
  }

  const float coeff = ComputeKing(num_entries, bit_sets + i * 2 * num_entries,
                                  bit_sets + (i * 2 + 1) * num_entries,
                                  bit_sets + j * 2 * num_entries,
                                  bit_sets + (j * 2 + 1) * num_entries);

  if (coeff > coeff_threshold) {
    // Reserve a result slot atomically to avoid collisions.
    const uint32_t reserved = atomicAdd(result_index, 1u);
    if (reserved < max_results) {
      KingResult &result = results[reserved];
      result.sample_i = i;
      result.sample_j = j;
      result.coeff = coeff;
    }
  }
}

// Returns ceil(a / b) for integers a, b.
template <typename T>
inline T CeilIntDiv(const T a, const T b) {
  return (a + b - 1) / b;
}

}  // namespace

int main(int argc, char **argv) {
  absl::ParseCommandLine(argc, argv);

  const auto &sample_map_file = absl::GetFlag(FLAGS_sample_map);
  if (sample_map_file.empty()) {
    std::cerr << "Error: no sample map file specified." << std::endl;
    return 1;
  }

  auto gcs_client =
      cuking::NewGcsClient(absl::GetFlag(FLAGS_num_reader_threads));
  auto sample_map_str = gcs_client->Read(sample_map_file);
  if (!sample_map_str.ok()) {
    std::cerr << "Error: failed to read sample map file: "
              << sample_map_str.status() << std::endl;
    return 1;
  }

  auto sample_map = nlohmann::json::parse(*sample_map_str);
  sample_map_str->clear();
  std::vector<std::string> sample_ids;
  std::vector<std::string> sample_paths;
  for (const auto &[id, path] : sample_map.items()) {
    sample_ids.push_back(id);
    sample_paths.push_back(path);
  }
  sample_map.clear();

  const size_t num_samples = sample_paths.size();
  auto samples = ReadSamples(sample_paths, gcs_client.get());
  if (!samples) {
    std::cerr << "Error: failed to read samples." << std::endl;
    return 1;
  }

  std::cout << "Read " << num_samples << " samples." << std::endl;

  const uint32_t kMaxResults = absl::GetFlag(FLAGS_max_results);
  auto results = NewCudaArray<KingResult>(kMaxResults);
  memset(results.get(), 0, sizeof(KingResult) * kMaxResults);
  auto result_index = NewCudaArray<uint32_t>(1);
  result_index[0] = 0;

  const absl::Time time_before = absl::Now();

  constexpr size_t kCudaBlockSize = 1024;
  const size_t kNumCudaBlocks =
      CeilIntDiv(num_samples * num_samples, kCudaBlockSize);
  ComputeKingKernel<<<kNumCudaBlocks, kCudaBlockSize>>>(
      num_samples, samples->num_entries, samples->bit_sets.get(),
      absl::GetFlag(FLAGS_king_coeff_threshold), kMaxResults, results.get(),
      result_index.get());

  // Wait for GPU to finish before accessing on host.
  cudaDeviceSynchronize();

  const absl::Time time_after = absl::Now();
  std::cout << "CUDA kernel time: " << (time_after - time_before) << std::endl;

  // Free some memory for postprocessing.
  samples->bit_sets.reset();

  const uint32_t num_results = result_index[0];
  if (num_results > kMaxResults) {
    std::cerr << "Error: could not store all results: try increasing the "
                 "--max_results parameter."
              << std::endl;
    return 1;
  }

  std::cout << "Found " << num_results
            << " coefficients above the cut-off threshold." << std::endl;

  std::vector<bool> related(num_samples);
  for (uint32_t i = 0; i < num_results; ++i) {
    const auto &result = results[i];
    related[result.sample_i] = related[result.sample_j] = true;
  }

  uint32_t num_related = 0;
  for (size_t i = 0; i < num_samples; ++i) {
    if (related[i]) {
      ++num_related;
    }
  }

  std::cout << num_related << " related samples found." << std::endl;

  // Create a map for JSON serialization.
  absl::flat_hash_map<std::string_view,
                      absl::flat_hash_map<std::string_view, float>>
      result_map;
  for (size_t i = 0; i < num_results; ++i) {
    const auto &result = results[i];
    result_map[sample_ids[result.sample_i]][sample_ids[result.sample_j]] =
        result.coeff;
  }

  if (const auto status = gcs_client->Write(absl::GetFlag(FLAGS_output),
                                            nlohmann::json(result_map).dump(4));
      !status.ok()) {
    std::cerr << "Failed to write output: " << status << std::endl;
    return 1;
  }

  return 0;
}
