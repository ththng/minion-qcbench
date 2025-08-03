/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { QUAST                  } from '../modules/nf-core/quast/main'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { load_qc_tools_config; get_enabled_qc_tools; get_enabled_assemblers; create_qctool_samplesheet; create_generic_assembler_samplesheet; QC_TOOL_EXECUTOR; ASSEMBLER_EXECUTOR } from '../subworkflows/local/utils_nfcore_qcbench_pipeline'
include { create_quast_samplesheet  } from '../subworkflows/local/utils_nfcore_qcbench_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow QCBENCH {

    take:
    ch_samplesheet // channel: samplesheet read in from --input

    main:

    ch_versions = Channel.empty()

    /*
    ====================================================================================
        EXTENSIBLE QC TOOLS STAGE
    ====================================================================================
    */

    // Load QC tools configuration
    def enabled_tools = get_enabled_qc_tools()
    def qc_output_channels = []

    // Execute enabled QC tools dynamically based on configuration
    enabled_tools.each { tool_name, tool_config ->
        tool_config.parameters.each { param_config ->
            // Get parameter values directly from configuration
            def module_args = param_config.values

            // Create samplesheet for this tool/parameter combination
            def ch_samplesheet_tool = create_qctool_samplesheet(ch_samplesheet, tool_name, module_args)

            // Execute QC tool using generic executor subworkflow
            QC_TOOL_EXECUTOR(ch_samplesheet_tool, tool_name, tool_config)

            qc_output_channels.add(QC_TOOL_EXECUTOR.out.output)
            ch_versions = ch_versions.mix(QC_TOOL_EXECUTOR.out.versions)
        }
    }

    // Merge all QC tool outputs into one channel
    if (qc_output_channels.size() == 0) {
        error "No QC tools are enabled or available. Please check conf/tools_config.yml"
    }

    ch_qc_tools = qc_output_channels.size() == 1 ?
        qc_output_channels[0] :
        qc_output_channels[0].mix(*qc_output_channels.drop(1))

    /*
    ====================================================================================
        EXTENSIBLE ASSEMBLY STAGE
    ====================================================================================
    */

    // Load assemblers configuration
    def enabled_assemblers = get_enabled_assemblers()
    def assembly_output_channels = []

    // Execute enabled assemblers dynamically based on configuration
    enabled_assemblers.each { assembler_name, assembler_config ->
        assembler_config.parameters.each { param_config ->
            // Get parameter values directly from configuration
            def assembler_args = param_config.values

            // Create mode channel for assembler parameters
            def ch_assembler_modes = create_generic_assembler_samplesheet(ch_qc_tools, assembler_args)

            // Execute assembler using generic executor subworkflow
            ASSEMBLER_EXECUTOR(ch_assembler_modes.samplesheet, ch_assembler_modes.mode, assembler_name, assembler_config)

            assembly_output_channels.add(ASSEMBLER_EXECUTOR.out.output)
            ch_versions = ch_versions.mix(ASSEMBLER_EXECUTOR.out.versions)
        }
    }

    // Merge all assembler outputs into one channel
    if (assembly_output_channels.size() == 0) {
        error "No assemblers are enabled or available. Please check conf/tools_config.yml"
    }

    ch_assembly = assembly_output_channels.size() == 1 ?
        assembly_output_channels[0] :
        assembly_output_channels[0].mix(*assembly_output_channels.drop(1))

    /*
    ====================================================================================
        QUALITY ASSESSMENT
    ====================================================================================
    */
    //
    // MODULE: QUAST
    //
    ch_samplesheet_quast = create_quast_samplesheet(ch_assembly)
    ch_fasta = params.quast_refseq ? file(params.quast_refseq) : []
    ch_gff = params.quast_features ? file(params.quast_features) : []
    QUAST(ch_samplesheet_quast, ['', ch_fasta], ['', ch_gff])
    ch_versions = ch_versions.mix(QUAST.out.versions)

    //
    // Collate and save software versions
    //
    softwareVersionsToYAML(ch_versions)
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name: 'minion_qcbench_software_versions.yml',
            sort: true,
            newLine: true
        ).set { ch_collated_versions }

    emit:
    quast_report_dir = QUAST.out.results
    versions         = ch_versions
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
