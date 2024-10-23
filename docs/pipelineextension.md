# minion-qcbench: Extending the pipeline

This page provides instructions for adding additional quality control tools to the pipeline. While the default pipeline includes options for filtering reads with [`Chopper`](https://github.com/wdecoster/chopper) or [`PRINSEQ++`](https://github.com/Adrian-Cantu/PRINSEQ-plus-plus), you may want to integrate other tools for the benchmarking.

This pipeline benchmarks quality control tools that filter reads based on a minimum average Phred score. However, when adding new tools, they don’t necessarily have to perform filtering; you can also include tools that perform other actions, such as trimming.

## Add new modules using nf-core/modules
All tools used in this pipeline are integrated through [`nf-core/modules`](https://nf-co.re/modules/), a collection of reusable, community-maintained Nextflow processes that facilitate the incorporation of software tools.

Follow [this guide](https://nf-co.re/docs/tutorials/nf-core_components/adding_modules_to_pipelines) for general instructions on adding modules to pipelines. However, not all steps are required for this pipeline. The following sections outline only the steps specific to `minion-qcbench`.

### Changes in `/minion-qcbench/workflows/qcbench.nf`
After installing and including the module in the `/minion-qcbench/workflows/qcbench.nf` file, insert its execution in the `QC TOOLS` section of the `/minion-qcbench/workflows/qcbench.nf` file as follows:

```groovy
//
// MODULE: <NEW_MODULE>
//
ch_samplesheet_qs_<new_module> = create_qctool_samplesheet(ch_samplesheet, '<new_module>', [<new_module_args>])
<NEW_MODULE>(ch_samplesheet_qs_<new_module>)
ch_<new_module>_filtered = <NEW_MODULE>.out.fastq
ch_versions = ch_versions.mix(<NEW_MODULE>.out.versions)
```

Next, merge the output of the new tool into the channel that collects all outputs from the various QC tools:

```groovy
//
// Merge all items emitted by the different QC tools into one channel
//
ch_qc_tools = ch_chopper_filtered
    .mix(ch_copyfastq, ch_prinseq_filtered, ch_<new_module>_filtered)
```

The `create_qctool_samplesheet` function adds metadata about the QC tool to the [`meta`](https://nf-co.re/docs/contributing/components/meta_map) variable, which is accessible throughout the pipeline. 

The third argument of the function is used to specify the command-line arguments required for the tool. For example, the tool `Chopper` has an option `-q <Phred score>` to filter reads by a minimum Phred average quality score. If you want to use scores of `13` and `15`, the third argument would be `[13,15]`. This information is added to the `meta`variable, more specifically the `meta.qc_args` field, making them available to the module when it runs the QC tool (see below).

### Changes in `/conf/modules.config`

The `/conf/modules.config` file defines the module's options, including arguments and output file naming conventions.

Add a section for the new module in the `/conf/modules.config` file like this:
```groovy
withName: <NEW_MODULE> {
    ext.args = { "<new_module option> ${meta.qc_args}" }
    ext.prefix = { "${meta.id}${meta.subsampling ? "_${meta.subsampling}" : '' }_<new_module>_${meta.qc_args}" }
}
```

The `ext.args`, `ext.args2` and `ext.args3` entries define the options for the tool. Depending on the module, one or more of these entries may be needed to specify the tool's command-line options. The `meta.qc_args` variable contains the specific arguments, as explained earlier, and is also used in the `ext.prefix` field to define the output file name prefix. This ensures that the outputs from different filtering or quality control actions can be easily identified.
