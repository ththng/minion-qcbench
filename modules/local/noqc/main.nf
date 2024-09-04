process NOQC {
    tag "$meta.id"
    label 'process_single'

    input:
    tuple val (meta), path (fastq)

    output:
    tuple val (meta), path ("*.fastq.gz")

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"

    """
    cp $fastq ${prefix}.fastq.gz
    """
}
