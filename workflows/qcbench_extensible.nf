/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { FLYE                   } from '../modules/nf-core/flye/main'
include { QUAST                  } from '../modules/nf-core/quast/main'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { COPYFASTQ              } from '../modules/local/copyfastq/main'
include { CHOPPER                } from '../modules/nf-core/chopper/main'
include { PRINSEQPLUSPLUS        } from '../modules/nf-core/prinseqplusplus/main'
include { load_qc_tools_config; get_enabled_qc_tools; create_qctool_samplesheet } from '../subworkflows/local/utils_nfcore_qcbench_pipeline'
include { create_flye_samplesheet   } from '../subworkflows/local/utils_nfcore_qcbench_pipeline'
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

    // Execute enabled QC tools directly based on configuration
    enabled_tools.each { tool_name, tool_config ->
        tool_config.parameters.each { param_config ->
            // Get parameter values directly from configuration
            def module_args = param_config.values

            // Create samplesheet for this tool/parameter combination
            def ch_samplesheet_tool = create_qctool_samplesheet(ch_samplesheet, tool_name, module_args)

            // Execute QC tool directly based on tool name
            switch(tool_name) {
                case 'copyfastq':
                    COPYFASTQ(ch_samplesheet_tool)
                    qc_output_channels.add(COPYFASTQ.out.fastq)
                    // COPYFASTQ doesn't emit versions
                    break

                case 'chopper':
                    CHOPPER(ch_samplesheet_tool)
                    qc_output_channels.add(CHOPPER.out.fastq)
                    ch_versions = ch_versions.mix(CHOPPER.out.versions)
                    break

                case 'prinseqplusplus':
                    PRINSEQPLUSPLUS(ch_samplesheet_tool)
                    qc_output_channels.add(PRINSEQPLUSPLUS.out.good_reads)
                    ch_versions = ch_versions.mix(PRINSEQPLUSPLUS.out.versions)
                    break

                default:
                    log.warn "QC tool '${tool_name}' is enabled in configuration but not implemented in workflow. Skipping..."
            }
        }
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
    params.flye_modes_list = params.flye_modes?.split(',') as List

    //
    // MODULE: FLYE
    //
    ch_samplesheet_flye = create_flye_samplesheet(ch_qc_tools, params.flye_modes_list)
    FLYE(ch_samplesheet_flye.samplesheet, ch_samplesheet_flye.mode)
    ch_assembly = FLYE.out.fasta
    ch_versions = ch_versions.mix(FLYE.out.versions)

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
