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
def load_tools_config() {
    def config_file = file("${projectDir}/conf/modules.yml")
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
    def config = load_tools_config()
    def enabled_tools = [:]

    config.qc_tools.each { tool_name, tool_config ->
        if (tool_config.enabled) {
            enabled_tools[tool_name] = tool_config
        }
    }

    return enabled_tools
}

//
// Get enabled tools from configuration
//
def get_enabled_tools(tool_type) {
    def config = load_tools_config()
    def enabled_tools = [:]

    if (tool_type === "qc") {
        config.qc_tools.each { tool_name, tool_config ->
            if (tool_config.enabled) {
                enabled_tools[tool_name] = tool_config
            }
        }
    }

    if (tool_type === "assembler") {
        config.assembler.each { tool_name, tool_config ->
            if (tool_config.enabled) {
                enabled_tools[tool_name] = tool_config
            }
        }
    }

    return enabled_tools
}


//
// Add information to the meta map about which QC tool is used with which option and which value is set for that option
// If multiple values are tested for option, multiple samplesheets are returned (one for each value per option)
//
def create_qctool_samplesheet(ch_samplesheet, qc_tool, qc_options) {
    if (!qc_options) {
        return ch_samplesheet.map { meta, filePath ->
            [meta + [qc_tool: qc_tool], filePath]
        }
    }
    return ch_samplesheet.flatMap { meta, filePath ->
        qc_options.collectMany { option_config ->
            def qc_option = option_config.option
            def additional_options = option_config?.additional_options ?: ''
            option_config.values.collect { qc_val ->
                def meta_map = meta + [qc_tool: qc_tool, qc_option: qc_option, qc_val: qc_val]
                if (additional_options) {
                    meta_map['additional_options'] = additional_options
                }
                [meta_map, filePath]
            }
        }
    }
}

def create_assembler_samplesheet(ch_samplesheet, assembler_options) {
    if (!assembler_options) {
        return ch_samplesheet
    }
    return ch_samplesheet.flatMap { meta, filePath ->
        assembler_options.collectMany { option_config ->
            def assembler_option = option_config.option
            def additional_options = option_config?.additional_options ?: ''
            option_config.values.collect { assembler_val ->
                def meta_map = meta + [assembler_option: assembler_option, assembler_val: assembler_val]
                if (additional_options) {
                    meta_map['assembler_additional_options'] = additional_options
                }
                [meta_map, filePath]
            }
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
