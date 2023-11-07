#!/usr/bin/env nextflow

nextflow.enable.dsl = 2



// WORKFLOW SPECIFICATION
// --------------------------------------------------------------- //
workflow {

	println()
    println("Note: This workflow currently only supports amplicons sequenced on an Illumina paired-end platform.")
    println("Support for long reads (PacBio and Oxford Nanopore) will be added in the future.")
	println("-----------------------------------------------------------------------------------------------")
	println()
	
	// input channels
	ch_reads = Channel
        .fromFilePairs( "${params.fastq_dir}/*{_R1,_R2}_001.fastq.gz", flat: true )

    ch_primer_bed = Channel
        .fromPath( params.primer_bed )

	ch_refseq = Channel
		.fromPath( params.reference )
	
	// Workflow steps
    MERGE_PAIRS (
        ch_reads
    )

    CLUMP_READS (
        MERGE_PAIRS.out
    )

    FIND_ADAPTER_SEQS (
        CLUMP_READS.out
    )

	TRIM_ADAPTERS (
        FIND_ADAPTER_SEQS.out
	)

    GET_PRIMER_SEQS (
        ch_primer_bed
    )

    FIND_COMPLETE_AMPLICONS (
        TRIM_ADAPTERS.out,
        GET_PRIMER_SEQS.out.patterns
    )

    REMOVE_OPTICAL_DUPLICATES (
		FIND_COMPLETE_AMPLICONS.out
	)

	REMOVE_LOW_QUALITY_REGIONS (
		REMOVE_OPTICAL_DUPLICATES.out
	)

	REMOVE_ARTIFACTS (
		REMOVE_LOW_QUALITY_REGIONS.out
	)

	ERROR_CORRECT_PHASE_ONE (
		REMOVE_ARTIFACTS.out
	)

	ERROR_CORRECT_PHASE_TWO (
		ERROR_CORRECT_PHASE_ONE.out
	)

	ERROR_CORRECT_PHASE_THREE (
		ERROR_CORRECT_PHASE_TWO.out
	)

	QUALITY_TRIM (
		ERROR_CORRECT_PHASE_THREE.out
	)

    EXTRACT_REF_AMPLICON (
		ch_refseq,
        GET_PRIMER_SEQS.out.amplicon_coords
    )

    MAP_TO_AMPLICON (
        QUALITY_TRIM.out,
        EXTRACT_REF_AMPLICON.out.seq
    )

    CLIP_AMPLICONS (
        MAP_TO_AMPLICON.out,
        GET_PRIMER_SEQS.out.bed
    )

    BAM_TO_FASTQ (
        CLIP_AMPLICONS.out
    )

    VALIDATE_SEQS (
        EXTRACT_REF_AMPLICON.out.length,
        BAM_TO_FASTQ.out
    )

    HAPLOTYPE_ASSEMBLY (
        VALIDATE_SEQS.out
    )

    // RECORD_FREQUENCIES (
    //     HAPLOTYPE_ASSEMBLY.out
    // )

	// GENERATE_CONSENSUS (
	// 	HAPLOTYPE_ASSEMBLY.out
	// )

	FILTER_ASSEMBLIES (
		HAPLOTYPE_ASSEMBLY.out.flatten()
	)

    MAP_ASSEMBLY_TO_REF (
        FILTER_ASSEMBLIES.out
			.map { name, reads -> tuple( name, file(reads), file(reads).countFastq() ) }
			.filter { it[2] >= params.min_reads }
			.map { name, reads, count -> tuple( name, file(reads) ) },
		ch_refseq
    )

	TRIM_PRIMERS (
		MAP_ASSEMBLY_TO_REF.out,
		ch_primer_bed
	)

	CALL_CONSENSUS_SEQS (
		TRIM_PRIMERS.out
	)

	EXTRACT_AMPLICON_CONSENSUS (
		CALL_CONSENSUS_SEQS.out
	)

    CALL_VARIANTS (
        TRIM_PRIMERS.out,
		ch_refseq
    )

    // GENERATE_REPORT (
    //     DOWNSAMPLE_ASSEMBLIES.out,
    //     MAP_ASSEMBLY_TO_REF.out,
    //     CALL_CONSENSUS_SEQS.out,
    //     CALL_VARIANTS.out
    // )
	
	
}
// --------------------------------------------------------------- //



// DERIVATIVE PARAMETER SPECIFICATION
// --------------------------------------------------------------- //
// Additional parameters that are derived from parameters set in nextflow.config

// overarching first level in results file hierarchy
params.amplicon_results = params.results + "/amplicon_${params.desired_amplicon}"

// Preprocessing results subdirectories
params.preprocessing = params.amplicon_results + "/01_preprocessing"
params.merged_reads = params.preprocessing + "/01_merged_pairs"
params.clumped_reads = params.preprocessing + "/02_clumped_reads"
params.trim_adapters = params.preprocessing + "/03_trim_adapters"
params.amplicon_reads = params.preprocessing + "/04_amplicon_reads"
params.optical_dedupe = params.preprocessing + "/05_optical_dedup"
params.low_quality = params.preprocessing + "/06_remove_low_quality"
params.remove_artifacts = params.preprocessing + "/07_remove_artifacts"
params.error_correct = params.preprocessing + "/08_error_correct"
params.qtrim = params.preprocessing + "/09_quality_trim"
params.clipped = params.preprocessing + "/10_clipped_reads"
params.complete_amplicon = params.preprocessing + "/11_complete amplicons"

// assembly results
params.assembly_results = params.amplicon_results + "/02_assembly_results"
params.assembly_reads = params.assembly_results + "/01_assembly_reads"
params.aligned_assembly = params.assembly_results + "/02_aligned_assemblies"
params.consensus = params.assembly_results + "/03_contigs"
params.variants = params.assembly_results + "/04_contig_variants"


// --------------------------------------------------------------- //




// PROCESS SPECIFICATION 
// --------------------------------------------------------------- //

process MERGE_PAIRS {

    /* */
	
	tag "${sample_id}"
    label "general"
	publishDir params.merged_reads, mode: 'copy', overwrite: true

	cpus 4

    input:
	tuple val(sample_id), path(reads1), path(reads2)

    output:
    tuple val(sample_id), path("${sample_id}_merged.fastq.gz")

    script:
    """
    bbmerge-auto.sh in1=`realpath ${reads1}` \
	in2=`realpath ${reads2}` \
    out=${sample_id}_merged.fastq.gz \
    outu=${sample_id}_unmerged.fastq.gz \
    strict k=93 extend2=80 rem ordered \
    ihist=${sample_id}_ihist_merge.txt \
    threads=${task.cpus}
    """

}

process CLUMP_READS {

    /*
    */
	
	tag "${sample_id}"
    label "general"
	publishDir params.clumped_reads, mode: 'copy', overwrite: true

	cpus 4
	
	input:
	tuple val(sample_id), path(reads)
	
	output:
    tuple val(sample_id), path("${sample_id}_clumped.fastq.gz")
	
	script:
	"""
	clumpify.sh in=${reads} out=${sample_id}_clumped.fastq.gz t=${task.cpus} reorder
	"""
}

process FIND_ADAPTER_SEQS {
	
	/* */
	
	tag "${sample_id}"
    label "general"

	errorStrategy { task.attempt < 3 ? 'retry' : errorMode }
	maxRetries 2

	cpus 4
	
	input:
	tuple val(sample_id), path(reads)
	
	output:
	tuple val(sample_id), path(reads), path("${sample_id}_adapters.fasta")
	
	script:
	"""
    bbmerge.sh in=`realpath ${reads}` outa="${sample_id}_adapters.fasta" ow qin=33
	"""

}

process TRIM_ADAPTERS {
	
	/* */
	
	tag "${sample_id}"
    label "general"
	publishDir params.trim_adapters, mode: 'copy', overwrite: true

	errorStrategy { task.attempt < 3 ? 'retry' : errorMode }
	maxRetries 2

	cpus 4
	
	input:
	tuple val(sample_id), path(reads), path(adapters)

    output:
    tuple val(sample_id), path("${sample_id}_no_adapters.fastq.gz")

    script:
    """
	reformat.sh in=`realpath ${reads}` \
	out=${sample_id}_no_adapters.fastq.gz \
	ref=`realpath ${adapters}` \
	uniquenames=t overwrite=true t=${task.cpus} -Xmx8g
    """

}

process GET_PRIMER_SEQS {

    /*
    */

	tag "${params.desired_amplicon}"
    label "general"

    input:
    path bed_file

    output:
    path "primer_seqs.bed", emit: bed
    path "primer_seqs.txt", emit: txt
	path "amplicon_coords.bed", emit: amplicon_coords
	path "patterns.txt", emit: patterns

    script:
    """

	# get the actual primer sequences and make sure the amplicon's reverse primer
	# is complementary to the reference sequence it's based on
    grep ${params.desired_amplicon} ${params.primer_bed} > primer_seqs.bed && \
    bedtools getfasta -fi ${params.reference} -bed primer_seqs.bed > tmp.fasta && \
	grep -v "^>" tmp.fasta > patterns.txt && \
	seqkit head -n 1 tmp.fasta -o primer_seqs.fasta && \
	seqkit range -r -1:-1 tmp.fasta | \
	seqkit seq --complement --validate-seq --seq-type DNA >> primer_seqs.fasta && \
	rm tmp.fasta

	# determine the amplicon coordinates
	cat primer_seqs.bed | \
	awk 'NR==1{start=\$2} NR==2{end=\$3} END{print \$1, start, end}' OFS="\t" \
	> amplicon_coords.bed

	# convert to a text file that can be read by `seqkit amplicon`
    seqkit fx2tab --no-qual primer_seqs.fasta | \
	awk '{print \$2}' | paste -sd \$'\t' - - | awk -v amplicon="${params.desired_amplicon}" \
	'BEGIN {OFS="\t"} {print amplicon, \$0}' | head -n 1 > primer_seqs.txt
    """

}

process FIND_COMPLETE_AMPLICONS {

    /*
    */

    tag "${sample_id}"
    label "general"
	publishDir params.amplicon_reads, mode: 'copy', overwrite: true

	cpus 4

    input:
	tuple val(sample_id), path(reads)
    path search_patterns
    
    output:
    tuple val(sample_id), path("${sample_id}_amplicons.fastq.gz")

    script:
    """
	cat ${reads} | \
    seqkit grep \
	--threads ${task.cpus} \
	--max-mismatch 3 \
	--by-seq \
	--pattern `head -n 1 ${search_patterns}` | \
	seqkit grep \
	--threads ${task.cpus} \
	--max-mismatch 3 \
	--by-seq \
	--pattern `tail -n 1 ${search_patterns}` \
    -o ${sample_id}_amplicons.fastq.gz
    """

}

process REMOVE_OPTICAL_DUPLICATES {

	/* 
	This process removes optical duplicates from the Illumina flow cell.
	*/

	tag "${sample_id}"
    label "general"
	publishDir params.optical_dedupe, pattern: "*.fastq.gz", mode: 'copy', overwrite: true

	cpus 4

	input:
	tuple val(sample_id), path(reads)

	output:
	tuple val(sample_id), path("${sample_id}_deduped.fastq.gz")

	script:
	"""
	clumpify.sh in=`realpath ${reads}` \
	out=${sample_id}_deduped.fastq.gz \
	threads=${task.cpus} \
	dedupe optical tossbrokenreads
	"""

}

process REMOVE_LOW_QUALITY_REGIONS {

	/* 
	Low quality regions of each read are removed in this process.
	*/

	tag "${sample_id}"
    label "general"
	publishDir params.low_quality, pattern: "*.fastq.gz", mode: 'copy', overwrite: true

	cpus 4

	input:
	tuple val(sample_id), path(reads)

	output:
	tuple val(sample_id), path("${sample_id}_filtered_by_tile.fastq.gz")

	script:
	"""
	filterbytile.sh in=`realpath ${reads}` \
	out=${sample_id}_filtered_by_tile.fastq.gz \
	threads=${task.cpus}
	"""

}

process REMOVE_ARTIFACTS {

	/* 
	Here we remove various contantimants that may have ended up in the reads,
	such as PhiX sequences that are often used as a sequencing control.
	*/

	tag "${sample_id}"
    label "general"
	publishDir params.remove_artifacts, pattern: "*.fastq.gz", mode: 'copy', overwrite: true

	cpus 4

	input:
	tuple val(sample_id), path(reads)

	output:
	tuple val(sample_id), path("${sample_id}_remove_artifacts.fastq.gz")

	script:
	"""
	bbduk.sh in=`realpath ${reads}` \
	out=${sample_id}_remove_artifacts.fastq.gz \
	k=31 ref=artifacts,phix ordered cardinality \
	threads=${task.cpus}
	"""

}

process ERROR_CORRECT_PHASE_ONE {

	/* 
	Bbmap recommends three phases of read error correction, the first of which
	goes through BBMerge.
	*/

	tag "${sample_id}"
    label "general"
	publishDir params.error_correct, pattern: "*.fastq.gz", mode: 'copy', overwrite: true

	cpus 4

	input:
	tuple val(sample_id), path(reads)

	output:
	tuple val(sample_id), path("${sample_id}_error_correct1.fastq.gz")

	script:
	"""
	bbmerge.sh in=`realpath ${reads}` \
	out=${sample_id}_error_correct1.fastq.gz \
	ecco mix vstrict ordered \
	ihist=${sample_id}_ihist_merge1.txt \
	threads=${task.cpus}
	"""

}

process ERROR_CORRECT_PHASE_TWO {

	/* 
	The second phase of error correction goes through clumpify.sh
	*/

	tag "${sample_id}"
    label "general"
	publishDir params.error_correct, pattern: "*.fastq.gz", mode: 'copy', overwrite: true

	cpus 4

	input:
	tuple val(sample_id), path(reads)

	output:
	tuple val(sample_id), path("${sample_id}_error_correct2.fastq.gz")

	script:
	"""
	clumpify.sh in=`realpath ${reads}` \
	out=${sample_id}_error_correct2.fastq.gz \
	ecc passes=4 reorder \
	threads=${task.cpus}
	"""

}

process ERROR_CORRECT_PHASE_THREE {

	/* 
	The third phase of error correction uses tadpole.sh.
	*/

	tag "${sample_id}"
    label "general"
	publishDir params.error_correct, pattern: "*.fastq.gz", mode: 'copy', overwrite: true

	cpus 4

	input:
	tuple val(sample_id), path(reads)

	output:
	tuple val(sample_id), path("${sample_id}_error_correct3.fastq.gz")

	script:
	"""
	tadpole.sh in=`realpath ${reads}` \
	out=${sample_id}_error_correct3.fastq.gz \
	ecc k=62 ordered \
	threads=${task.cpus}
	"""

}

process QUALITY_TRIM {

	/* 
	Here we quality trim reads from both ends to a minimum Phred quality of 10, 
	and enforce a minimum read length of 70 bases. 
	*/

	tag "${sample_id}"
    label "general"
	publishDir params.qtrim, pattern: "*.fastq.gz", mode: 'copy', overwrite: true

	cpus 4

	input:
	tuple val(sample_id), path(reads)

	output:
	tuple val(sample_id), path("${sample_id}_qtrimmed.fastq.gz")

	script:
	"""
	bbduk.sh in=`realpath ${reads}` \
	out=${sample_id}_qtrimmed.fastq.gz \
	qtrim=rl trimq=10 minlen=70 ordered \
	threads=${task.cpus}
	"""

}

process EXTRACT_REF_AMPLICON {

    /* */

	tag "${params.desired_amplicon}"
    label "general"

    input:
	path refseq
    path amplicon_coords

    output:
    path "amplicon.fasta", emit: seq
    env len, emit: length

    script:
    """
	cat ${refseq} | \
    seqkit subseq \
	--bed ${amplicon_coords} \
    -o amplicon.fasta && \
    seqkit fx2tab --no-qual --length amplicon.fasta -o amplicon.stats && \
    len=`cat amplicon.stats | tail -n 1 | awk '{print \$3}'`
    """

}

process MAP_TO_AMPLICON {

    /*
    */
	
	tag "${sample_id}"
    label "general"

	cpus 4
	
	input:
	tuple val(sample_id), path(reads)
    path amplicon_seq
	
	output:
	tuple val(sample_id), path("${sample_id}_sorted.bam"), path("${sample_id}_sorted.bam.bai")
	
	script:
	"""
	bbmap.sh ref=${amplicon_seq} in=${reads} out=stdout.sam t=${task.cpus} maxindel=200 | \
	samtools sort -o ${sample_id}_sorted.bam - && \
	samtools index -o ${sample_id}_sorted.bam.bai ${sample_id}_sorted.bam
	"""
}

process CLIP_AMPLICONS {

    /*
    */
	
	tag "${sample_id}"
    label "general"
	publishDir params.clipped, mode: 'copy', overwrite: true

	cpus 4
	
	input:
	tuple val(sample_id), path(bam), path(index)
    path amplicon_bed
	
	output:
    tuple val(sample_id), path("${sample_id}_clipped.bam")
	
	script:
	"""
	samtools ampliconclip \
	-b ${amplicon_bed} \
	--soft-clip \
	--both-ends \
	--clipped \
	${sample_id}_sorted.bam \
	-o ${sample_id}_clipped.bam
	"""
}

process BAM_TO_FASTQ {

    /*
    */
	
	tag "${sample_id}"
    label "general"
	publishDir params.clipped, mode: 'copy', overwrite: true

	cpus 4
	
	input:
	tuple val(sample_id), path(bam)
	
	output:
	tuple val(sample_id), path("*.fastq.gz")
	
	script:
	"""
	reformat.sh in=${bam} out=stdout.fastq t=${task.cpus} | \
	clumpify.sh in=stdin.fastq out=${sample_id}_amplicon_reads.fastq.gz t=${task.cpus} reorder
	"""
}

process VALIDATE_SEQS {

    /*
    */
	
	tag "${sample_id}"
    label "general"
	publishDir params.complete_amplicon, mode: 'copy'

	cpus 4
	
	input:
    val amplicon_length
	tuple val(sample_id), path(reads)
	
	output:
	tuple val(sample_id), path("*.fastq.gz")
	
	script:
	"""
	cat ${reads} | \
    seqkit seq \
	--threads ${task.cpus} \
	--remove-gaps \
	--validate-seq \
    -o ${sample_id}_filtered.fastq.gz
	"""
}

process HAPLOTYPE_ASSEMBLY {

    /*
    */
	
	tag "${sample_id}"
    // label "general"
	// publishDir params.assembly_reads, pattern: "*Contig*", mode: 'copy'

    cpus 8
	
	input:
	tuple val(sample_id), path(reads)
	
	output:
	path "*.fastq.gz"

	when:
	params.geneious_mode == true
	
	script:
	"""
	geneious -i ${reads} -x ${params.assembly_profile} -o ${sample_id}.fastq.gz --multi-file && \
	for file in *Contig*.fastq.gz; do
		mv "\$file" "\${file// /_}"
	done
	"""
}

// process RECORD_FREQUENCIES {

//     /*
//     */
	
// 	tag "${sample_id}"
//    label "general"
// 	publishDir params.results, mode: 'copy'
	
// 	input:
	
	
// 	output:
	
	
// 	script:
// 	"""
	
// 	"""
// }

process FILTER_ASSEMBLIES {

	/* */

	tag "${file_name}"
    label "general"
	publishDir params.assembly_reads, mode: 'copy', overwrite: true

	errorStrategy 'ignore'

    cpus 4

	input:
	path assembly_reads

	output:
	tuple val(file_name), path("*.fastq.gz")

	when:
	assembly_reads.getSimpleName().contains("Contig")

	script:
	sample_id = assembly_reads.getSimpleName().split("_L00")[0]
	contig_num = assembly_reads.getName().split(".fastq.gz")[0].replace("Unpaired", "").split("_")[-1]
	file_name = sample_id + "_contig" + contig_num
	"""
	clumpify.sh in="${assembly_reads}" out="${file_name}.fastq.gz" reorder
	"""

}

process MAP_ASSEMBLY_TO_REF {

    /*
    */
	
	tag "${name}"
    label "general"
	publishDir params.aligned_assembly, mode: 'copy', overwrite: true

	errorStrategy 'ignore'

    cpus 4
	
	input:
	tuple val(name), path(assembly_reads)
	each path(refseq)
	
	output:
	tuple val(name), path("*.bam")
	
	script:
	"""
	bbmap.sh int=f ref=${refseq} in=${assembly_reads} out=stdout.sam maxindel=200 | \
	reformat.sh in=stdin.sam out="${name}.bam"
	"""

}

process TRIM_PRIMERS {

    /*
    */
	
	tag "${name}"
    label "iVar"

	errorStrategy 'ignore'

    cpus 4
	
	input:
	tuple val(name), path(bam)
	each path(primer_bed)
	
	output:
	tuple val(name), path("*.bam")
	
	script:
	"""
    ivar trim -b ${primer_bed} -i ${bam} -q 15 -m 50 -s 4 -p ${name}_trimmed
	"""
}

process CALL_CONSENSUS_SEQS {

    /*
    */
	
	tag "${name}"
    label "iVar"
	// publishDir params.consensus, mode: 'copy', overwrite: true

	errorStrategy 'ignore'

    cpus 4
	
	input:
	tuple val(name), path(bam)
	
	output:
	tuple val(name), path("${name}_consensus.fa*")
	
	script:
	"""
	samtools mpileup -aa -A -d 0 -Q 0 "${bam}" | ivar consensus -t 0.5 -p ${name}_consensus
	"""

}

process EXTRACT_AMPLICON_CONSENSUS {

	/* */
	
	tag "${name}"
    label "general"
	publishDir params.consensus, mode: 'copy', overwrite: true

	errorStrategy 'ignore'
	
	input:
	tuple val(name), path(fasta)
	
	output:
	tuple val(name), path("${name}_${params.desired_amplicon}_consensus.fa*")
	
	script:
	"""
	cat ${fasta} | \
	seqkit replace \
	--ignore-case \
	--by-seq \
	--pattern "N" \
	--replacement "" \
	-o "${name}_${params.desired_amplicon}_consensus.fa"
	"""


}

process CALL_VARIANTS {

    /*
    */
	
	tag "${name}"
    label "general"
	publishDir params.variants, mode: 'copy', overwrite: true

	errorStrategy 'ignore'

    cpus 4
	
	input:
	tuple val(name), path(bam)
	each path(refseq)
	
	output:
	tuple val(name), path("${name}.vcf")
	
	script:
	"""
    bcftools mpileup -Ou -f ${refseq} ${bam} | bcftools call --ploidy 1 -mv -Ov -o ${name}.vcf
	"""

}

// process GENERATE_REPORT {
	
// 	// This process does something described here
	
// 	tag "${sample_id}"
// 	publishDir params.results, mode: 'copy'
	
// 	memory 1.GB
// 	cpus 1
// 	time '10minutes'
	
// 	input:
	
	
// 	output:
	
	
// 	when:
	
	
// 	script:
// 	"""
	
// 	"""
// }

// --------------------------------------------------------------- //
