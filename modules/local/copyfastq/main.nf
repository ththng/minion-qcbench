process COPYFASTQ {
    tag "$meta.id"
    label 'process_single'

    input:
    tuple val (meta), path (fastq)

    output:
    tuple val (meta), path ("*.fastq.gz"), emit: fastq

    when:
    task.ext.when == null || task.ext.when

    script:
    def args   = task.ext.args   ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"


    """
    cp $args $fastq ${prefix}.fastq.gz
    """
    
    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    
    """
    echo stub | gzip -c > ${prefix}.fastq.gz
    """
}
