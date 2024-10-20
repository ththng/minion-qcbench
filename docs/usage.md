# minion-qcbench: Usage
<!-- TODO: Add the software requirements! -->

> If you are new to Nextflow and nf-core, please refer to [this page](https://nf-co.re/docs/usage/installation) on how to set-up Nextflow.

## Pipeline Validation: Running Tests
Before running the full pipeline, it is recommended to execute the provided test cases to ensure that the pipeline is correctly configured and functioning as expected.

<!-- TODO: setup profile test! -->
Make sure to [test your setup](https://nf-co.re/docs/usage/introduction#how-to-run-a-pipeline) with `-profile test` before running the workflow on actual data.

...TODO...

## Samplesheet input

You will need to create a samplesheet with information about the samples you would like to analyse before running the pipeline. It has to be a comma-separated file with 3 columns, and a header row as shown in the example below.

Use this parameter to specify its location.

```bash
--input '[path to samplesheet file]'
```

### Full samplesheet

The samplesheet can have as many columns as you desire, however, there is a strict requirement for the first 3 columns to match those defined in the table below.

| Column    | Description                                                                                                                                                                            |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sample`  | Custom sample name. |
| `fastq` | Full path to FastQ file for long-read sequencing data. File has to be gzipped and have the extension ".fastq.gz" or ".fq.gz".                                                             |
| `subsampling` | Subsampling rate.                                                             |

**Example `samplesheet.csv`**

```csv
sample,fastq,subsampling
sample1,sample1.fastq.gz,
sample1,sample1_80.fastq.gz,80
sample2,sample2.fastq.gz,
```

The first row represents a sample named `sample1`, which was not subsampled, so the last value is omitted. The second row corresponds to the same sample, subsampled at 80%. The third row refers to a different sample, `sample2`, which was also not subsampled.

<!-- TODO: subsampling ??? path to sample ???
-->

## Running the pipeline

Assuming the following folder structure:
```
.
├── data                      # Data folder containing the samplesheet
│   ├── samplesheet.csv       # Samplesheet referencing the FASTQ files
│   ├── sample1.fastq.gz
│   ├── sample1_80.fastq.gz
│   ├── sample2.fastq.gz
│   └── ...
└── minion-qcbench            # This project
    └── ...

```

After navigating to the **parent** directory of the `minion-qcbench` project, you can run the pipeline using the minimal example command below, which includes the essential parameters. This is a minimal example; additional optional parameters can be specified as needed.

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
| `-profile <PROFILE>` | Configuration profile; available options include `singularity`, `docker`, `conda`, among others. For this pipeline, `singularity` is recommended, as the pipeline was developed and tested using this profile. See [below](#core-nextflow-arguments) for more information about profiles. |
| `--input <PATH/TO/SAMPLESHEET.CSV>` | Path to the samplesheet |
| `--outdir <OUTDIR>` | The output directory where the results will be saved |
| `--quality_scores <SCORE1,SCORE2,...>` | Minimum Phred average quality scores by which the QC tools filter, separated by comma |
| `--flye_modes <FLYE_MODE1,FLYE_MODE2,...>` | Flye modes used for assembly, representing the underlying sequencing technology, separated by comma (supported options: `pacbio-raw`, `pacbio-corr`, `pacbio-hifi`, `nano-raw`, `nano-corr`, `nano-hq`) |

**Optional parameters**
| Parameter | Description |
| --------- | ------- |
| `--flye_genome_size <GENOME_SIZE>` | Estimated genome size e.g. `4.4m` |
| `--quast_refseq <PATH/TO/REFERENCE_GENOME>` | Path to reference genome file |
| `--quast_features <PATH/TO/GENOMIC_FEATURES>` | Path to file with genomic feature positions in the reference genome; valid file formats are described in the [QUAST manual](https://quast.sourceforge.net/docs/manual.html#sec2.2) |


Note that the pipeline will create the following files in your working directory:

```bash
work                # Directory containing the nextflow working files
<OUTDIR>            # Finished results in specified location (defined with --outdir)
.nextflow_log       # Log file from Nextflow
# Other nextflow hidden files, eg. history of pipeline runs and old logs.
```

## Core Nextflow arguments

> These options are part of Nextflow and use a _single_ hyphen (pipeline parameters use a double-hyphen).

### `-profile`

Use this parameter to choose a configuration profile. Profiles can give configuration presets for different compute environments.

Several generic profiles are bundled with the pipeline which instruct the pipeline to use software packaged using different methods (Docker, Singularity, Podman, Shifter, Charliecloud, Apptainer, Conda) - see below.

> For this pipeline, `singularity` is recommended, as the pipeline was developed and tested using this profile.

Note that multiple profiles can be loaded, for example: `-profile test,singularity` - the order of arguments is important!
They are loaded in sequence, so later profiles can overwrite earlier profiles.

If `-profile` is not specified, the pipeline will run locally and expect all software to be installed and available on the `PATH`. This is _not_ recommended, since it can lead to different results on different machines dependent on the computer enviroment.

- `test`
  - A profile with a complete configuration for automated testing
  - Includes links to test data so needs no other parameters
- `docker`
  - A generic configuration profile to be used with [Docker](https://docker.com/)
- `singularity`
  - A generic configuration profile to be used with [Singularity](https://sylabs.io/docs/)
- `podman`
  - A generic configuration profile to be used with [Podman](https://podman.io/)
- `shifter`
  - A generic configuration profile to be used with [Shifter](https://nersc.gitlab.io/development/shifter/how-to-use/)
- `charliecloud`
  - A generic configuration profile to be used with [Charliecloud](https://hpc.github.io/charliecloud/)
- `apptainer`
  - A generic configuration profile to be used with [Apptainer](https://apptainer.org/)
- `wave`
  - A generic configuration profile to enable [Wave](https://seqera.io/wave/) containers. Use together with one of the above (requires Nextflow ` 24.03.0-edge` or later).
- `conda`
  - A generic configuration profile to be used with [Conda](https://conda.io/docs/). Please only use Conda as a last resort i.e. when it's not possible to run the pipeline with Docker, Singularity, Podman, Shifter, Charliecloud, or Apptainer.

### `-resume`

Specify this when restarting a pipeline. Nextflow will use cached results from any pipeline steps where the inputs are the same, continuing from where it got to previously. For input to be considered the same, not only the names must be identical but the files' contents as well. For more info about this parameter, see [this blog post](https://www.nextflow.io/blog/2019/demystifying-nextflow-resume.html).

You can also supply a run name to resume a specific run: `-resume [run-name]`. Use the `nextflow log` command to show previous run names.

### `-c`

Specify the path to a specific config file (this is a core Nextflow command). See the [nf-core website documentation](https://nf-co.re/usage/configuration) for more information.

## Custom configuration

### Resource requests

Whilst the default requirements set within the pipeline will hopefully work for most people and with most input data, you may find that you want to customise the compute resources that the pipeline requests. Each step in the pipeline has a default set of requirements for number of CPUs, memory and time. For most of the steps in the pipeline, if the job exits with any of the error codes specified [here](https://github.com/nf-core/rnaseq/blob/4c27ef5610c87db00c3c5a3eed10b1d161abf575/conf/base.config#L18) it will automatically be resubmitted with higher requests (2 x original, then 3 x original). If it still fails after the third attempt then the pipeline execution is stopped.

To change the resource requests, please see the [max resources](https://nf-co.re/docs/usage/configuration#max-resources) and [tuning workflow resources](https://nf-co.re/docs/usage/configuration#tuning-workflow-resources) section of the nf-core website.

### Custom Containers

In some cases you may wish to change which container or conda environment a step of the pipeline uses for a particular tool. By default nf-core pipelines use containers and software from the [biocontainers](https://biocontainers.pro/) or [bioconda](https://bioconda.github.io/) projects. However in some cases the pipeline specified version maybe out of date.

To use a different container from the default container or conda environment specified in a pipeline, please see the [updating tool versions](https://nf-co.re/docs/usage/configuration#updating-tool-versions) section of the nf-core website.

### Custom Tool Arguments

A pipeline might not always support every possible argument or option of a particular tool used in pipeline. Fortunately, nf-core pipelines provide some freedom to users to insert additional parameters that the pipeline does not include by default.

## Running in the background

Nextflow handles job submissions and supervises the running jobs. The Nextflow process must run until the pipeline is finished.

The Nextflow `-bg` flag launches Nextflow in the background, detached from your terminal so that the workflow does not stop if you log out of your session. The logs are saved to a file.

Alternatively, you can use `screen` / `tmux` or similar tool to create a detached session which you can log back into at a later time.
Some HPC setups also allow you to run nextflow within a cluster job submitted your job scheduler (from where it submits more jobs).

## Nextflow memory requirements

In some cases, the Nextflow Java virtual machines can start to request a large amount of memory.
We recommend adding the following line to your environment to limit this (typically in `~/.bashrc` or `~./bash_profile`):

```bash
NXF_OPTS='-Xms1g -Xmx4g'
```
