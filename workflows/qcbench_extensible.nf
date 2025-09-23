/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { FLYE                   } from '../modules/nf-core/flye/main'
include { QUAST                  } from '../modules/nf-core/quast/main'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { get_enabled_qc_tools; get_enabled_tools; create_qctool_samplesheet; create_assembler_samplesheet } from '../subworkflows/local/utils_nfcore_qcbench_pipeline'
include { QC_TOOL_EXECUTOR; ASSEMBLER_EXECUTOR } from '../subworkflows/local/qc_tool_executor_helper'
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
    def enabled_qctools = get_enabled_qc_tools()
    //def enabled_qctools = get_enabled_tools("qc")
    def qc_output_channels = []

    // Execute enabled QC tools dynamically based on configuration
    enabled_qctools.each { tool_name, tool_config ->
        def ch_samplesheet_tool = create_qctool_samplesheet(ch_samplesheet, tool_name, tool_config.options)
        QC_TOOL_EXECUTOR(ch_samplesheet_tool, tool_name, tool_config)
        qc_output_channels.add(QC_TOOL_EXECUTOR.out.output)
        ch_versions = ch_versions.mix(QC_TOOL_EXECUTOR.out.versions)
    }

    // Merge all QC tool outputs into one channel
    if (qc_output_channels.size() == 0) {
        error "No QC tools are enabled or available. Please check conf/qc_tools.yml"
    }

    ch_qc_tools = qc_output_channels.size() == 1 ?
        qc_output_channels[0] :
        qc_output_channels[0].mix(*qc_output_channels.drop(1))

    /*
    ====================================================================================
        ASSEMBLY
    ====================================================================================
    */
    def enabled_assemblers = get_enabled_tools("assembler")
    def assembler_names = enabled_assemblers.keySet().toList()
    def first_assembler_name = assembler_names[0]
    def first_assembler_config = enabled_assemblers[first_assembler_name]

    if (enabled_assemblers.size() == 0) {
        error "No assemblers are enabled or available. Please check conf/qc_tools.yml"
    }
    ch_samplesheet_assembler = create_assembler_samplesheet(ch_qc_tools, first_assembler_config.options)
    ASSEMBLER_EXECUTOR(ch_samplesheet_assembler)
    ch_assembly = ASSEMBLER_EXECUTOR.out.output
    ch_versions = ch_versions.mix(ASSEMBLER_EXECUTOR.out.versions)

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
