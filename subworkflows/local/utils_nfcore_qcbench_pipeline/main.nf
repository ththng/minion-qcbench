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

// QC Tool imports
include { COPYFASTQ } from '../../../modules/local/copyfastq/main'
include { CHOPPER } from '../../../modules/nf-core/chopper/main'
include { PRINSEQPLUSPLUS } from '../../../modules/nf-core/prinseqplusplus/main'
// Add more QC tool imports here as needed

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
    def String workflow_command = "nextflow run ${workflow.manifest.name} -profile <docker/singularity/.../institute> --input samplesheet.csv --outdir <OUTDIR> --flye_modes <FLYE_MODE1,FLYE_MODE2,...>"
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
            meta, fastq ->
                return [ meta + [ single_end:true ], [ fastq ] ]
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
// Load QC tools configuration from YAML file
//
def load_qc_tools_config() {
    def config_file = file("${projectDir}/conf/qc_tools.yml")
    if (!config_file.exists()) {
        error "QC tools configuration file not found: ${config_file}"
    }

    def yaml = new org.yaml.snakeyaml.Yaml()
    def config = yaml.load(config_file.text)

    return config
}

//
// Get enabled QC tools from configuration
//
def get_enabled_qc_tools() {
    def config = load_qc_tools_config()
    def enabled_tools = [:]

    config.qc_tools.each { tool_name, tool_config ->
        if (tool_config.enabled) {
            enabled_tools[tool_name] = tool_config
        }
    }

    return enabled_tools
}


//
// Add information to the meta map about which QC tool is used and which parameters are set
// If multiple parameter sets are tested for one tool, multiple samplesheets are returned (one for each parameter set)
//
def create_qctool_samplesheet(ch_samplesheet, qc_tool, qc_args) {
    return ch_samplesheet.flatMap { meta, filePath ->
        qc_args.collect { qc_arg ->
            [meta + [qc_arg: qc_arg, qc: qc_tool], filePath]
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

/*
    QC TOOL EXECUTOR SUBWORKFLOW
*/

//
// Generic QC Tool Executor Subworkflow
// This subworkflow executes QC tools based on configuration
// NOTE: Nextflow requires static imports - dynamic module loading is not possible
//
workflow QC_TOOL_EXECUTOR {

    take:
    ch_samplesheet  // channel: samplesheet with metadata
    tool_name       // string: name of the QC tool to execute
    tool_config     // map: tool configuration from YAML

    main:

    ch_versions = Channel.empty()
    ch_output = Channel.empty()

    // Module functions map - generated statically by wrapper script
    // DYNAMIC_FUNCTIONS_START
    def module_functions = [
        'COPYFASTQ': { ch -> COPYFASTQ(ch) },
        'CHOPPER': { ch -> CHOPPER(ch) },
        'PRINSEQPLUSPLUS': { ch -> PRINSEQPLUSPLUS(ch) }
    ]
    // DYNAMIC_FUNCTIONS_END

    // Execute QC tool using function reference
    def module_name = tool_config.module
    def output_channel = tool_config.output_channel

    if (module_functions.containsKey(module_name)) {
        // Get the function reference and execute it
        def module_function = module_functions[module_name]
        def process_result = module_function(ch_samplesheet)

        // Get output channel dynamically
        ch_output = process_result.out."${output_channel}"

        // Add versions if available (some tools don't emit versions)
        if (process_result.out.versions) {
            ch_versions = ch_versions.mix(process_result.out.versions)
        }

        log.info "Successfully executed QC tool: ${tool_name} (${module_name})"
    } else {
        log.error "QC tool '${tool_name}' module '${module_name}' is not available in module_functions map."
        log.error "Available modules: ${module_functions.keySet()}"
        log.error "Please ensure the module is imported and added to the function map."
        error "Unsupported QC tool module: ${module_name}"
    }

    emit:
    output   = ch_output
    versions = ch_versions
}
