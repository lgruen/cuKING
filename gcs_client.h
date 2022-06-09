#pragma once

#include <absl/status/statusor.h>
#include <google/cloud/storage/client.h>

#include <string_view>

namespace cuking {

namespace gcs = google::cloud::storage;

class GcsClient {
 public:
  virtual ~GcsClient() = default;

  virtual absl::StatusOr<std::string> Read(std::string_view url) const = 0;

  virtual absl::Status Write(std::string_view url,
                             std::string content) const = 0;

  virtual absl::StatusOr<gcs::ObjectWriteStream> WriteStream(
      std::string_view url) const = 0;
};

std::unique_ptr<GcsClient> NewGcsClient(size_t max_connection_pool_size);

}  // namespace cuking
