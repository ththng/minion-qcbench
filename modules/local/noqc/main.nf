process NOQC {
    tag "$meta.id"
    label 'process_single'

    input:
    tuple val (meta), path (reads)

    output:
    tuple val (meta), val (prefix), path ("*.fastq.gz")

    when:
    task.ext.when == null || task.ext.when

    script:
    prefix = "${meta.id}_noqc"

    """
    cp $reads ${prefix}.fastq.gz
    """
}
