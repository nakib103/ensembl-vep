=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2019] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut


=head1 CONTACT

 Please email comments or questions to the public Ensembl
 developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

 Questions may also be sent to the Ensembl help desk at
 <http://www.ensembl.org/Help/Contact>.

=cut


=head1 ImportCGC

This module imports Cancer Gene Census data. The module fetched the data from
OpenTargets project https://www.targetvalidation.org/downloads/data

=cut

package Bio::EnsEMBL::Variation::Pipeline::PhenotypeAnnotation::ImportCGC;

use warnings;
use strict;

use File::Path qw(make_path);
use File::Basename;
use DateTime;
use JSON;

use Bio::EnsEMBL::Variation::Pipeline::PhenotypeAnnotation::BasePhenotypeAnnotation;
use base ('Bio::EnsEMBL::Variation::Pipeline::BaseVariationProcess');

my %source_info;
my $workdir;

my $basePheno;

sub fetch_input {
  my $self = shift;

  my $pipeline_dir = $self->required_param('pipeline_dir');
  my $species      = $self->required_param('species');

  $basePheno = Bio::EnsEMBL::Variation::Pipeline::PhenotypeAnnotation::BasePhenotypeAnnotation->new("debug" => $self->param('debug_mode'));
  $basePheno->core_db_adaptor($self->get_species_adaptor('core'));
  $basePheno->variation_db_adaptor($self->get_species_adaptor('variation'));
  $basePheno->ontology_db_adaptor($self->get_adaptor('multi', 'ontology'));

  %source_info = (source_description => 'Catalog of genes of which mutations have been causally implicated in cancer',
                  source_url => 'http://cancer.sanger.ac.uk/census',
                  object_type => 'Gene',
                  #source_version  will be set based on the date in the file name (year/month-> yyyymm)
                  source_status => 'somatic',
                  source_name => 'Cancer Gene Census',     #source name in the variation db
                  source_name_short => 'CancerGeneCensus', #source identifier in the pipeline
                  );

  $workdir = $pipeline_dir."/".$source_info{source_name_short}."/".$species;
  make_path($workdir);
  my $cgc_google_url = 'https://storage.googleapis.com/open-targets-data-releases/';
  # example of URL format: https://storage.googleapis.com/open-targets-data-releases/18.12/output/18.12_evidence_data.json.gz';

  open (my $logFH, ">", $workdir."/".'log_import_out_'.$source_info{source_name_short}.'_'.$species) || die ("Failed to open file: $!\n");
  open (my $errFH, ">", $workdir."/".'log_import_err_'.$source_info{source_name_short}.'_'.$species) || die ("Failed to open file: $!\n");
  open (my $pipelogFH, ">", $workdir."/".'log_import_debug_pipe_'.$source_info{source_name_short}.'_'.$species) || die ("Failed to open file: $!\n");
  $basePheno->logFH($logFH);
  $basePheno->errFH($errFH);
  $basePheno->pipelogFH($pipelogFH);

  #get input file CGC via OpenTargets, get latest published file:
  my $dt = DateTime->now;
  my $year = sprintf("%02d", $dt->year % 100);
  my $month = sprintf ("%02d",$dt->month);
  my $cgc_ftp_url = $cgc_google_url.$year.'.'.$month.'/output/'.$year.'.'.$month.'_evidence_data.json.gz';

  my $file_opent = basename($cgc_ftp_url); #OpenTargets file
  print $logFH "INFO: Found file ($file_opent), will skip new fetch\n" if -e $workdir."/".$file_opent;
  my $found = (-e $workdir."/".$file_opent ? 1: 0);

  while (!$found){
    if ($month == 01){ $month =12; $year = $year-1;}
    else { $month = $month -1;}
    $month = sprintf ("%02d",$month);
    my $cgc_check_url = $cgc_google_url.$year.'.'.$month.'/output/'.$year.'.'.$month.'_evidence_data.json.gz';
    $file_opent = basename($cgc_check_url);

    if (-e $workdir."/".$file_opent){
      $found = 1;
      print $logFH "INFO: Found $file_opent, will skip new fetch.\n";
      next;
    }

    my $resHTTPcode = qx{curl -w %{http_code} -X GET $cgc_check_url -o '$workdir/$file_opent'};
    if ($resHTTPcode == 404){ #Not Found
      unlink($workdir."/".$file_opent) if -e $workdir."/".$file_opent;
      print $errFH "WARNING: No OpenTarget file found for current month ($file_opent), will check past month.\n";
    } elsif ($resHTTPcode == 200){ #Successful
      print $errFH "HTTP code 200 (successful) but file ($file_opent) is missing \n" unless -e $workdir."/".$file_opent;
    }
    if (-e $workdir."/".$file_opent) { $found = 1;}
  }
  # get only Cancer Gene Census files
  $source_info{source_version} = "20$year$month";
  my $file_cgc_json = "open_targets_20$year-$month.json";
  print $logFH "INFO: Found files (".$workdir."/".$file_cgc_json."), will skip new zcat\n" if -e $workdir."/".$file_cgc_json;
  `zcat $workdir/$file_opent | grep "Cancer Gene Census" > $workdir/$file_cgc_json` unless -e $workdir."/".$file_cgc_json;

  $self->param('cgc_file', $file_cgc_json);
}

sub run {
  my $self = shift;

  my $file_cgc = $self->required_param('cgc_file');
  my $file_cgc_ensembl = "cgc_ensembl_efo.txt";

  #augment data with data from Ensembl and EFO based on get_cancer_gene_census.pl
  $basePheno->print_logFH("Retrieving data from Ensembl and EFO based on CancerGeneCensus file\n");
  $basePheno->print_logFH("INFO: Found file ($file_cgc_ensembl), will skip new fetch\n") if -e $workdir."/".$file_cgc_ensembl;
  get_cancer_gene_census_file($file_cgc, $file_cgc_ensembl) unless -e  $workdir."/".$file_cgc_ensembl;
  $basePheno->print_logFH("Done retrieving Ensembl core and onotlogy data, if file was already present it will be reused.\n");

  #get source id
  my $source_id = $basePheno->get_or_add_source(\%source_info);
  $basePheno->print_logFH("$source_info{source_name_short} source_id is $source_id\n") if ($basePheno->debug);

  # get phenotype data + save it (all in one method)
  my $results = parse_cancer_gene_census($file_cgc_ensembl);
  $basePheno->print_logFH( "Parsed ".(scalar @{$results->{'phenotypes'}})." new phenotypes \n") if ($basePheno->debug);

  # save phenotypes
  $basePheno->save_phenotypes(\%source_info, $results) unless scalar(@{$results->{'phenotypes'}}) == 0;

  my %param_source = (source_name => $source_info{source_name_short},
                      type => $source_info{object_type});
  $self->param('output_ids', { source => \%param_source,
                               species => $self->required_param('species')
                             });
}

sub write_output {
  my $self = shift;

  $basePheno->print_pipelogFH("Passing $source_info{source_name_short} import (".$self->required_param('species').") for checks (check_phenotypes)\n") if ($basePheno->debug);
  close($basePheno->logFH) if defined $basePheno->logFH ;
  close($basePheno->errFH) if defined $basePheno->errFH ;
  close($basePheno->pipelogFH) if defined $basePheno->pipelogFH ;

  $self->dataflow_output_id($self->param('output_ids'), 1);

}


#CancerGeneCensus specific data prep
sub get_cancer_gene_census_file {
  my $input_file = shift;
  my $output_file = shift;

  my $errFH1;
  open ($errFH1, ">", $workdir."/".'log_import_err_'.$input_file) || die ("Failed to open file: $!\n");

  my %efos;
  my %data;

  my $ga = $basePheno->core_db_adaptor->get_GeneAdaptor;
  die("ERROR: Could not get gene adaptor\n") unless defined($ga);
  my $ota = $basePheno->ontology_db_adaptor->get_OntologyTermAdaptor;
  die("ERROR: Could not get ontology term adaptor\n") unless defined($ota);

  if($input_file =~ /gz$/) {
    open (IN, "zcat $workdir/$input_file |") || die ("Could not open $input_file for reading: $!\n");
  }
  else {
    open (IN,'<',$workdir."/".$input_file) || die ("Could not open $input_file for reading: $!\n");
  }

  while(<IN>) {
    chomp $_;
    my $json_hash = decode_json($_);

    my $source = $json_hash->{'sourceID'};
    next unless ($source =~ /cancer_gene_census/);

    my $type          = $json_hash->{'type'};
    my $gene_symbol   = $json_hash->{'target'}{'gene_info'}{'symbol'};
    my $pmids         = parse_publications($json_hash->{'literature'}{'references'});
    my $phenotype_url = $json_hash->{'unique_association_fields'}{'disease_uri'};

    # Phenotype fetching and parsing
    $phenotype_url =~ /\/(\w+)$/;
    my $phenotype_id = $1;
    my $phenotype;
    if ($phenotype_id =~ /^EFO/) {
      $phenotype = ($efos{$phenotype_id}) ? $efos{$phenotype_id} : get_phenotype_desc($phenotype_id, $ota);
    }

    if (!$phenotype) {
      print $errFH1 "$gene_symbol: no phenotype desc found for $phenotype_id\n";
      $phenotype = 'ND';
    }
    else {
      $efos{$phenotype_id} = $phenotype;
    }
    
    my $genes = $ga->fetch_all_by_external_name($gene_symbol, 'HGNC');		
    # we don't want any LRG genes
    @$genes = grep {$_->stable_id !~ /^LRG_/} @$genes;

    my %stable_ids;
    if (scalar @$genes != 1) {
      my $gene_id = $json_hash->{'target'}{'id'};
      $gene_id =~ /(ENSG\d+)$/i;
      if ($1) {
        $stable_ids{$1} = 1;
      }
      print $errFH1 "WARNING: Found ".(scalar @$genes)." matching Ensembl genes for HGNC ID $gene_symbol\n";
    }

    next unless scalar @$genes;

    foreach my $gene(@$genes) {
      my $gene_id = $gene->stable_id;
      next if (%stable_ids && !$stable_ids{$gene_id});

      $data{$gene_symbol}{$gene_id}{$phenotype}{'type'} = $type;
      $data{$gene_symbol}{$gene_id}{$phenotype}{'source'} = $source;
      $data{$gene_symbol}{$gene_id}{$phenotype}{'phenotype_id'} = $phenotype_id;
      foreach my $pmid (@$pmids) {
        $data{$gene_symbol}{$gene_id}{$phenotype}{'pmids'}{$pmid} = 1; 
      }
    }
  }
  close(IN);

  open (OUT, "> $workdir/$output_file") || die ("Could not open file for writing: $!\n");
  foreach my $gene_symbol (sort(keys(%data))) {
    foreach my $gene_id (keys(%{$data{$gene_symbol}})) {
      foreach my $phenotype (keys(%{$data{$gene_symbol}{$gene_id}})) {
        my $type         = $data{$gene_symbol}{$gene_id}{$phenotype}{'type'};
        my $source       = $data{$gene_symbol}{$gene_id}{$phenotype}{'source'};
        my $phenotype_id = $data{$gene_symbol}{$gene_id}{$phenotype}{'phenotype_id'};
        my $pmids = join(',', keys(%{$data{$gene_symbol}{$gene_id}{$phenotype}{'pmids'}}));
        print OUT "$gene_symbol\t$gene_id\t$type\t$source\t$phenotype\t$phenotype_id\t$pmids\n";
      }
    }
  }

  close(OUT);

  close ($errFH1);
}

sub get_phenotype_desc {
  my $id = shift;
  my $ota = shift;

  $id =~ s/ //g;
  $id =~ s/_/:/g;

  my $phenotype;
  my $term = $ota->fetch_by_accession($id);
  $phenotype = $term->name if ($term);

  return $phenotype;
}

sub parse_publications {
  my $pubs = shift;

  my @pmids = ();
  foreach my $pub (@$pubs) {
    my $pub_id = $pub->{'lit_id'};
    $pub_id=~ /^http:\/\/europepmc.org\/abstract\/MED\/(\d+)$/i;
    if ($1) {
      my $pmid = "PMID:$1";
      push @pmids,$pmid;
    }
  }
  return \@pmids;
}


# CGC specific phenotype parsing method
sub parse_cancer_gene_census {
  my $infile = shift;

  my $errFH1;
  open ($errFH1, ">", $workdir."/".'log_import_err_'.$infile) || die ("Failed to open file".$workdir."/".'log_import_err_'.$infile.": $!\n");

  my $ga = $basePheno->core_db_adaptor->get_GeneAdaptor;
  die("ERROR: Could not get gene adaptor\n") unless defined($ga);

  my @phenotypes;

  # Open the input file for reading
  if($infile =~ /gz$/) {
    open (IN, "zcat $workdir/$infile |") || die ("Could not open $infile for reading: $!\n");
  }
  else {
    open (IN,'<',$workdir."/".$infile) || die ("Could not open $infile for reading: $!\n");
  }

  # Read through the file and parse out the desired fields
  while (<IN>) {
    chomp;

    my @row_data = split(/\t/, $_);

    # get data
    my $gene_id   = $row_data[1];
    my $phen      = $row_data[4];
    my $accession = $row_data[5];
    my $pmids     = $row_data[6];

    ## change accession format
    $accession =~ s/\_/\:/;

    my $gene = $ga->fetch_by_stable_id($gene_id);

    if(!$gene) {
      print $errFH1 "WARNING: Ensembl gene $gene_id not found in the Ensembl Core database. Skipped!\n";
      next;
    }

    my %data = (
      'id' => $gene_id,
      'description' => $phen,
      'seq_region_id' => $gene->slice->get_seq_region_id,
      'seq_region_start' => $gene->seq_region_start,
      'seq_region_end' => $gene->seq_region_end,
      'seq_region_strand' => $gene->seq_region_strand,
      'accessions' => [$accession],
      'ontology_mapping_type' => 'is'
    );

    $data{'study'} = $pmids if ($pmids);

    push(@phenotypes,\%data);
  }
  close(IN);
  close($errFH1);

  my %result = ('phenotypes' => \@phenotypes);
  return \%result;
}

1;
