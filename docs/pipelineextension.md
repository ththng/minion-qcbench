# minion-qcbench: Extending the pipeline

This page provides instructions on how to add additional quality control tools to the pipeline. While the default pipeline includes options for filtering reads with Chopper and PRINSEQ++, you may want to integrate other tools.

## nf-core/modules
All tools used in this pipeline are integrated through [`nf-core/modules`](https://nf-co.re/modules/), a collection of reusable, community-maintained Nextflow processes that facilitate the incorporation of software tools.
