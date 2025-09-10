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

// QC Tool Executor Helper
include { execute_qc_tool } from '../qc_tool_executor_helper/main'

// Assembler Executor Helper
include { execute_assembler } from '../assembler_executor_helper/main'

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
// Load tools configuration from YAML file
//
def load_qc_tools_config() {
    def config_file = file("${projectDir}/conf/tools_config.yml")
    if (!config_file.exists()) {
        error "Tools configuration file not found: ${config_file}"
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
// Get enabled assemblers from configuration
//
def get_enabled_assemblers() {
    def config = load_qc_tools_config()
    def enabled_assemblers = [:]

    config.assemblers.each { assembler_name, assembler_config ->
        if (assembler_config.enabled) {
            enabled_assemblers[assembler_name] = assembler_config
        }
    }

    return enabled_assemblers
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
// Generic assembler samplesheet creator that works with different assemblers
// Creates mode/parameter input based on assembler configuration
//
def create_generic_assembler_samplesheet(ch_samplesheet, assembler_args) {
    return ch_samplesheet
        .flatMap { meta, filePath ->
            assembler_args.collect { arg ->
                [meta + [assembler_mode: arg], filePath]
            }
        }
        // To-Do: Many modules do not use multimap - make it more generic
        .multiMap { meta, fastq ->
            def mode_input = "--" + meta.assembler_mode
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
// This subworkflow executes QC tools based on configuration using the helper function
// NOTE: Nextflow requires static imports - dynamic module loading is not possible
//
workflow QC_TOOL_EXECUTOR {

    take:
    ch_samplesheet  // channel: samplesheet with metadata
    tool_name       // string: name of the QC tool to execute
    tool_config     // map: tool configuration from YAML

    main:

    // Execute QC tool using helper function
    def module_name = tool_config.module
    def output_channel = tool_config.output_channel

    // Call the helper function that contains the dynamically generated switch cases
    def (ch_output, ch_versions) = execute_qc_tool(ch_samplesheet, module_name, output_channel)

    log.info "Successfully executed QC tool: ${tool_name} (${module_name})"

    emit:
    output   = ch_output
    versions = ch_versions
}

/*
    ASSEMBLER EXECUTOR SUBWORKFLOW
*/

//
// Generic Assembler Executor Subworkflow
// This subworkflow executes assemblers based on configuration using the helper function
// NOTE: Nextflow requires static imports - dynamic module loading is not possible
//
workflow ASSEMBLER_EXECUTOR {

    take:
    ch_samplesheet  // channel: samplesheet with metadata
    ch_mode         // channel: assembler mode/parameters
    assembler_name  // string: name of the assembler to execute
    assembler_config // map: assembler configuration from YAML

    main:

    // Execute assembler using helper function
    def module_name = assembler_config.module
    def output_channel = assembler_config.output_channel

    // Call the helper function that contains the dynamically generated switch cases
    def (ch_output, ch_versions) = execute_assembler(ch_samplesheet, ch_mode, module_name, output_channel)

    log.info "Successfully executed assembler: ${assembler_name} (${module_name})"

    emit:
    output   = ch_output
    versions = ch_versions
}
