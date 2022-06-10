#!/usr/bin/env python3

import hail as hl
from cpg_utils.hail_batch import init_batch, output_path

DENSE_HGDP_1KG_TABLE = 'gs://gcp-public-data--gnomad/release/3.1.2/mt/genomes/gnomad.genomes.v3.1.2.hgdp_1kg_subset_dense.mt'
AF_THRESHOLD = 0.05
TARGET_COUNT = 250000


def main():
    init_batch()

    mt = hl.read_matrix_table(DENSE_HGDP_1KG_TABLE)
    mt = mt.filter_rows(mt.gnomad_freq.AF < AF_THRESHOLD)
    mt = mt.sample(TARGET_COUNT / mt.count())
    mt = mt.filter_cols(mt.hgdp_tgp_meta.project == '1000 Genomes')
    kinship = hl.king(mt.GT)
    kinship.write(output_path('king_1kg.mt'))


if __name__ == '__main__':
    main()
