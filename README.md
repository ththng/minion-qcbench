## Introduction

**minion-qcbench** is a bioinformatics pipeline that benchmarks different quality control tools on long-read sequencing data. It takes a samplesheet and sequencing data (FASTQ files) as input, pre-processes them with different quality control tools, assembles these pre-processed reads using Flye and compares the resulting assemblies using QUAST, which computes various quality metrics and summarises them in reports.

<!-- TODO nf-core: Include a figure that guides the user through the major workflow steps. Many nf-core
     workflows use the "tube map" design for that. See https://nf-co.re/docs/contributing/design_guidelines#examples for examples.   -->

1. Filter reads using [`Chopper`](https://github.com/wdecoster/chopper) or [`PRINSEQ++`](https://github.com/Adrian-Cantu/PRINSEQ-plus-plus) by a minimum average phred score or leave the reads unfiltered
2. Assemble the preprocessed sequencing data using [`Flye`](https://github.com/fenderglass/Flye)
3. Calculate quality metrics for the assemblies [`QUAST`](https://github.com/ablab/quast)

## Usage
> If you are new to Nextflow and nf-core, please refer to [this page](https://nf-co.re/docs/usage/installation) on how to set-up Nextflow.

First, prepare a samplesheet with your input data that looks as follows:

`samplesheet.csv`:

```csv
sample,fastq,subsampling
sample1,sample1.fastq.gz,
sample1,sample1_80.fastq.gz,80
sample2,sample2.fastq.gz,
```

<!-- TODO: subsampling ???
-->
Each row represents a sample with the sample ID, the path to the respective FASTQ file and how it was subsampled.

Assuming the following folder structure:
```
.
├── data                      # Data folder containing the samplesheet
│   ├── samplesheet.csv       # Samplesheet referencing the FASTQ files
│   └── ...
└── minion-qcbench            # This project
    └── ...

```

After navigating to the **parent** directory of the `minion-qcbench` project, you can run the pipeline using the minimal example command below, which includes the essential parameters.

```bash
nextflow run minion-qcbench \
   -profile singularity \
   --input data/samplesheet.csv \
   --outdir results
   --quality_scores 13,15               # Minimum Phred average quality scores
   --flye_modes nano-corr,nano-hq       # Flye modes used for assembly
```

## Output
The final step of the pipeline is the execution of [`QUAST`](https://github.com/ablab/quast), which evaluates the quality of the assembled genome. QUAST generates a comprehensive report that provides insights into the accuracy and completeness of the assembly. This report includes various metrics such as contig counts, N50, GC content, and alignment statistics against the reference genome (if provided). For more information about QUAST reports, see <https://quast.sourceforge.net/docs/manual.html>.

Upon completion of the pipeline, the QUAST reports can be found in the directory `<OUTDIR>/quast`. The directory will contain separate subdirectories for each sample, with an individual QUAST report generated for each sample.

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