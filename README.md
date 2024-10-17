## Introduction

**minion-qcbench** is a bioinformatics pipeline that benchmarks different quality control tools on long-read sequencing data. It takes a samplesheet and sequencing data (FASTQ files) as input, pre-processes them with different quality control tools, assembles these pre-processed reads using Flye and compares the resulting assemblies using QUAST, which computes various quality metrics and summarises them in reports.

<!-- TODO nf-core: Include a figure that guides the user through the major workflow steps. Many nf-core
     workflows use the "tube map" design for that. See https://nf-co.re/docs/contributing/design_guidelines#examples for examples.   -->

1. Filter reads using [`Chopper`](https://github.com/wdecoster/chopper) or [`PRINSEQ++`](https://github.com/Adrian-Cantu/PRINSEQ-plus-plus) by a minimum average phred score or leave the reads unfiltered
2. Assemble the preprocessed sequencing data using [`Flye`](https://github.com/fenderglass/Flye)
3. Calculate quality metrics for the assemblies [`QUAST`](https://github.com/ablab/quast)

## Usage
<!-- TODO setup profile test! -->
> [!NOTE]
> If you are new to Nextflow and nf-core, please refer to [this page](https://nf-co.re/docs/usage/installation) on how to set-up Nextflow. Make sure to [test your setup](https://nf-co.re/docs/usage/introduction#how-to-run-a-pipeline) with `-profile test` before running the workflow on actual data.

<!-- TODO Zuerst Test ausführen in Doku aufnehmen! -->

First, prepare a samplesheet with your input data that looks as follows:

`samplesheet.csv`:

```csv
sample,fastq,subsampling
sample1,sample1.fastq.gz,
sample1,sample1_80.fastq.gz,80
sample2,sample2.fastq.gz,
```

<!-- TODO: subsampling ??? path to sample ???
-->
Each row represents a sample with the sample ID, the path to the respective FASTQ file and how it was subsampled. The path is relative to the samplesheet.\
In this example, the first row of samples represents a sample called `sample1`, which was not subsampled, and the second row represents the same sample, but subsampled by 80%. Here, the FASTQ files are in the same directory as the samplesheet.

Assuming the following folder structure:
```
.
├── data                      # Data folder containing the samplesheet
│   ├── genomic.fna
│   ├── samplesheet.csv       # Samplesheet referencing the FASTQ files
│   ├── sample1.fastq.gz
│   ├── sample1_80.fastq.gz
│   ├── sample2.fastq.gz
│   └── ...
└── minion-qcbench            # This project
    └── ...

```

After navigating to the **parent** directory of the `minion-qcbench` project, you can run the pipeline using the example command below, which includes the essential parameters. This is a minimal example; additional optional parameters can be specified as needed.

```bash
nextflow run minion-qcbench \
   -profile singularity \
   --input data/samplesheet.csv \
   --outdir results
   --quality_scores 13,15
   --flye_modes nano-corr,nano-hq
```

**Required parameters**
| Parameter | Description |
| --------- | ------- |
| `-profile <PROFILE>` | Specifies the execution environment for the pipeline. Available options include `conda`, `docker`, `apptainer`, among others. For this pipeline, `singularity` is recommended, as the pipeline was developed and tested using this environment |
| `--input <PATH/TO/SAMPLESHEET.CSV>` | Path to the samplesheet |
| `--outdir <OUTDIR>` | The output directory where the results will be saved |
| `--quality_scores <SCORE1,SCORE2,...>` | Minimum Phred average quality scores by which the QC tools filter, separated by comma |
| `--flye_modes <FLYE_MODE1,FLYE_MODE2,...>` | Flye modes used for assembly, representing the underlying sequencing technology, separated by comma (supported options: `pacbio-raw`, `pacbio-corr`, `pacbio-hifi`, `nano-raw`, `nano-corr`, `nano-hq`) |

**Optional parameters**
| Parameter | Description |
| --------- | ------- |
| `--flye_genome_size <GENOME_SIZE>` | Estimated genome size e.g. `4.4m` |
| `--quast_refseq <PATH/TO/REFERENCE_GENOME>` | Path to reference genome file |
| `--quast_features <PATH/TO/GENOMIC_FEATURES>` | Path to file with genomic feature positions in the reference genome |

## Output
The final step of the pipeline is the execution of [`QUAST`](https://github.com/ablab/quast), which evaluates the quality of the assembled genome. Upon completion of the pipeline, the QUAST reports can be found in the directory `<OUTDIR>/quast`. The directory will contain separate subdirectories for each sample, with an individual QUAST report generated for each sample.

**Example**
```
.
├── data                      # Data folder containing the samplesheet
├── minion-qcbench            # This project
└── results                   # --outdir is set to "results"
     ├── ...
     └── quast
          ├── sample1
          └── sample2

```

## Citations
An extensive list of references for the tools used by the pipeline can be found in the [`CITATIONS.md`](CITATIONS.md) file.

This pipeline uses code and infrastructure developed and maintained by the [nf-core](https://nf-co.re) community, reused here under the [MIT license](https://github.com/nf-core/tools/blob/master/LICENSE).

> **The nf-core framework for community-curated bioinformatics pipelines.**
>
> Philip Ewels, Alexander Peltzer, Sven Fillinger, Harshil Patel, Johannes Alneberg, Andreas Wilm, Maxime Ulysse Garcia, Paolo Di Tommaso & Sven Nahnsen.
>
> _Nat Biotechnol._ 2020 Feb 13. doi: [10.1038/s41587-020-0439-x](https://dx.doi.org/10.1038/s41587-020-0439-x).
>
> In addition, references of tools and data used in this pipeline are as follows: