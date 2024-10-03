/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { COPYFASTQ              } from '../modules/local/copyfastq/main'
include { CHOPPER                } from '../modules/nf-core/chopper/main'
include { PRINSEQPLUSPLUS        } from '../modules/nf-core/prinseqplusplus/main'
include { FLYE                   } from '../modules/nf-core/flye/main'
include { QUAST                  } from '../modules/nf-core/quast/main'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { create_qctool_samplesheet, create_flye_samplesheet, create_quast_samplesheet } from '../subworkflows/local/utils_nfcore_qcbench_pipeline'

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
        QC TOOLS
    ====================================================================================
    */
    params.quality_scores_list = params.quality_scores?.split(',') as List

    //
    // MODULE: COPYFASTQ
    //
    ch_samplesheet_copyfastq = create_qctool_samplesheet(ch_samplesheet, 'copyfastq', [0])
    COPYFASTQ(ch_samplesheet_copyfastq)
    ch_copyfastq = COPYFASTQ.out.fastq

    //
    // MODULE: CHOPPER
    //
    ch_samplesheet_qs_chopper = create_qctool_samplesheet(ch_samplesheet, 'chopper', params.quality_scores_list)
    CHOPPER(ch_samplesheet_qs_chopper)
    ch_chopper_filtered = CHOPPER.out.fastq
    ch_versions = ch_versions.mix(CHOPPER.out.versions)

    //
    // MODULE: PRINSEQ
    //
    ch_samplesheet_qs_prinseq = create_qctool_samplesheet(ch_samplesheet, 'prinseq', params.quality_scores_list)
    PRINSEQPLUSPLUS(ch_samplesheet_qs_prinseq)
    ch_prinseq_filtered = PRINSEQPLUSPLUS.out.good_reads
    ch_versions = ch_versions.mix(PRINSEQPLUSPLUS.out.versions)

    //
    // Merge all items emitted by the different QC Tools into one channel
    //
    ch_qc_tools = ch_chopper_filtered
        .mix(ch_copyfastq, ch_prinseq_filtered)

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

    // Print the Quast report directory to stdout
    QUAST.out.results.view { meta, path -> "The quast report for ${meta["id"]} is stored in ${path}." }

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
