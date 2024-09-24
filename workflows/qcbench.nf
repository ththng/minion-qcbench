/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { FASTQC                 } from '../modules/nf-core/fastqc/main'
include { MULTIQC                } from '../modules/nf-core/multiqc/main'
include { COPYFASTQ              } from '../modules/local/copyfastq/main'
include { CHOPPER                } from '../modules/nf-core/chopper/main'
include { PRINSEQPLUSPLUS        } from '../modules/nf-core/prinseqplusplus/main'
include { FLYE                   } from '../modules/nf-core/flye/main'
include { QUAST                  } from '../modules/nf-core/quast/main'
include { paramsSummaryMap       } from 'plugin/nf-validation'
include { paramsSummaryMultiqc   } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText } from '../subworkflows/local/utils_nfcore_qcbench_pipeline'
include { create_qctool_samplesheet } from '../subworkflows/local/utils_nfcore_qcbench_pipeline'
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
    //QUAST.out.results.map { it[0] }.view()

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

    /*
    ch_multiqc_files = Channel.empty()

    //
    // MODULE: Run FastQC
    //
    FASTQC (
        ch_samplesheet
    )
    ch_multiqc_files = ch_multiqc_files.mix(FASTQC.out.zip.collect{it[1]})
    ch_versions = ch_versions.mix(FASTQC.out.versions.first())

    //
    // Collate and save software versions
    //
    softwareVersionsToYAML(ch_versions)
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name: 'nf_core_pipeline_software_mqc_versions.yml',
            sort: true,
            newLine: true
        ).set { ch_collated_versions }

    //
    // MODULE: MultiQC
    //
    ch_multiqc_config        = Channel.fromPath(
        "$projectDir/assets/multiqc_config.yml", checkIfExists: true)
    ch_multiqc_custom_config = params.multiqc_config ?
        Channel.fromPath(params.multiqc_config, checkIfExists: true) :
        Channel.empty()
    ch_multiqc_logo          = params.multiqc_logo ?
        Channel.fromPath(params.multiqc_logo, checkIfExists: true) :
        Channel.empty()

    summary_params      = paramsSummaryMap(
        workflow, parameters_schema: "nextflow_schema.json")
    ch_workflow_summary = Channel.value(paramsSummaryMultiqc(summary_params))

    ch_multiqc_custom_methods_description = params.multiqc_methods_description ?
        file(params.multiqc_methods_description, checkIfExists: true) :
        file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)
    ch_methods_description                = Channel.value(
        methodsDescriptionText(ch_multiqc_custom_methods_description))

    ch_multiqc_files = ch_multiqc_files.mix(
        ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(ch_collated_versions)
    ch_multiqc_files = ch_multiqc_files.mix(
        ch_methods_description.collectFile(
            name: 'methods_description_mqc.yaml',
            sort: true
        )
    )

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList()
    )

    emit:
    multiqc_report = MULTIQC.out.report.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                 // channel: [ path(versions.yml) ]
    */
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
