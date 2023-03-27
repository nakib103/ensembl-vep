#!/usr/bin/env nextflow

/* 
 * Script to merge chromosome-wise VCF files into single VCF file
 */

nextflow.enable.dsl=2

// defaults
params.cpus = 1

process mergeVCF {
  /*
  Function to merge chromosome-wise VCF files into single VCF file

  Returns
  -------
  Returns 2 files:
      1) A VCF format file 
      2) A tabix index for that VCF
  */

  cpus params.cpus
  container "${params.singularity_dir}/bcftools.sif"
  
  cache 'lenient'

   
  input:
  path(vcfFiles)
  path(indexFiles)
  val(outdir)
  val(output_prefix)

  output:
  val("${outdir}/${output_prefix}.vcf.gz"), emit: vcfFile
  val("${outdir}/${output_prefix}.vcf.gz.tbi"), emit: indexFile

  script: 
  """
  temp_output_file=${ outdir }/temp-${ output_prefix }.vcf.gz
  bcftools concat --no-version -a ${ vcfFiles } -Oz -o \${temp_output_file}
  
  mkdir -p temp
  output_file=${ outdir }/${ output_prefix }.vcf.gz
  bcftools sort -T temp -Oz \${temp_output_file} -o \${output_file}
  
  bcftools index -t \${output_file}
  
  rm \${temp_output_file}
  """
}
