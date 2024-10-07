//
// Subworkflow with functionality specific to the minion-qcbench pipeline
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { UTILS_NFVALIDATION_PLUGIN } from '../../nf-core/utils_nfvalidation_plugin'
include { paramsSummaryMap          } from 'plugin/nf-validation'
include { fromSamplesheet           } from 'plugin/nf-validation'
include { UTILS_NEXTFLOW_PIPELINE   } from '../../nf-core/utils_nextflow_pipeline'
include { completionSummary         } from '../../nf-core/utils_nfcore_pipeline'
include { dashedLine                } from '../../nf-core/utils_nfcore_pipeline'
include { workflowHeader            } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NFCORE_PIPELINE     } from '../../nf-core/utils_nfcore_pipeline'

/*
========================================================================================
    SUBWORKFLOW TO INITIALISE PIPELINE
========================================================================================
*/

workflow PIPELINE_INITIALISATION {

    take:
    version           // boolean: Display version and exit
    help              // boolean: Display help text
    validate_params   // boolean: Boolean whether to validate parameters against the schema at runtime
    monochrome_logs   // boolean: Do not use coloured log outputs
    nextflow_cli_args //   array: List of positional nextflow CLI args
    outdir            //  string: The output directory where the results will be saved
    input             //  string: Path to input samplesheet

    main:

    ch_versions = Channel.empty()

    //
    // Print version and exit if required and dump pipeline parameters to JSON file
    //
    UTILS_NEXTFLOW_PIPELINE (
        version,
        true,
        outdir,
        workflow.profile.tokenize(',').intersect(['conda', 'mamba']).size() >= 1
    )

    //
    // Validate parameters and generate parameter summary to stdout
    //
    pre_help_text = workflowHeader(monochrome_logs)
    post_help_text = '\n'
    def String workflow_command = "nextflow run ${workflow.manifest.name} -profile <docker/singularity/.../institute> --input samplesheet.csv --outdir <OUTDIR>"
    UTILS_NFVALIDATION_PLUGIN (
        help,
        workflow_command,
        pre_help_text,
        post_help_text,
        validate_params,
        "nextflow_schema.json"
    )

    //
    // Check config provided to the pipeline
    //
    UTILS_NFCORE_PIPELINE (
        nextflow_cli_args
    )

    //
    // Create channel from input file provided through params.input
    //
    Channel
        .fromSamplesheet("input")
        .map {
            meta, fastq_1, fastq_2 ->
                if (fastq_2) {
                    // Raise an error if paired-end data is detected
                    error("Paired-end data is not allowed. Please check the input samplesheet for sample: ${meta.id}")
                }
                return [ meta + [ single_end:true ], [ fastq_1 ] ]
        }
        .set { ch_samplesheet }

    emit:
    samplesheet = ch_samplesheet
    versions    = ch_versions
}

/*
========================================================================================
    SUBWORKFLOW FOR PIPELINE COMPLETION
========================================================================================
*/

workflow PIPELINE_COMPLETION {

    take:
    outdir          //    path: Path to output directory where results will be published
    monochrome_logs // boolean: Disable ANSI colour codes in log output

    main:

    //
    // Completion summary
    //
    workflow.onComplete {
        completionSummary(monochrome_logs)
    }

    workflow.onError {
        log.error "Pipeline failed. Please refer to troubleshooting docs: https://nf-co.re/docs/usage/troubleshooting"
    }
}

/*
========================================================================================
    FUNCTIONS
========================================================================================
*/

//
// Add information to the meta map about which QC tool is used and which min mean quality score is set as threshold
// If multiple quality thresholds are tested for one tool, multiple samplesheets are returned (one for each quality threshold)
//
def create_qctool_samplesheet(ch_samplesheet, qc_tool, quality_scores) {
    return ch_samplesheet.flatMap { meta, filePath ->
        quality_scores.collect { quality ->
            [meta + [quality: quality, qc: qc_tool], filePath]
        }
    }
}

//
// Add information to the meta map about which Flye mode is used
// If multiple Flye modes are tested, multiple samplesheets (one for each mode) are created
// Since Flye has 2 input channels (one for the sample, one for the mode), 2 channels are returned for each samplesheet
//
def create_flye_samplesheet(ch_samplesheet, modes) {
    return ch_samplesheet
        .flatMap { meta, filePath ->
            modes.collect { mode ->
                [meta + [mode: mode], filePath]
            }
        } 
        .multiMap { meta, fastq ->
            def mode_input = "--" + meta.mode
            samplesheet: [meta, fastq]
            mode: mode_input
        }
}

//
// Multiple assemblies are emitted from the previous process Flye, especially if there are multiple initial input samples
// To create a separate QUAST report for each sample, the assemblies are grouped by the sample id
//
def create_quast_samplesheet(ch_samplesheet) {
    return ch_samplesheet.map { meta, filePath ->
        [[id: meta.id], filePath]
    }.groupTuple()
}
