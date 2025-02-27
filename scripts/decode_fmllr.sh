#!/usr/bin/env bash

# Copyright 2012-2015  Johns Hopkins University (Author: Daniel Povey)

# Decoding script that does fMLLR.  This can be on top of delta+delta-delta, or
# LDA+MLLT features.

# There are 3 models involved potentially in this script,
# and for a standard, speaker-independent system they will all be the same.
# The "alignment model" is for the 1st-pass decoding and to get the
# Gaussian-level alignments for the "adaptation model" the first time we
# do fMLLR.  The "adaptation model" is used to estimate fMLLR transforms
# and to generate state-level lattices.  The lattices are then rescored
# with the "final model".
#
# The following table explains where we get these 3 models from.
# Note: $srcdir is one level up from the decoding directory.
#
#   Model              Default source:
#
#  "alignment model"   $srcdir/final.alimdl              --alignment-model <model>
#                     (or $srcdir/final.mdl if alimdl absent)
#  "adaptation model"  $srcdir/final.mdl                 --adapt-model <model>
#  "final model"       $srcdir/final.mdl                 --final-model <model>


# Begin configuration section
first_beam=10.0 # Beam used in initial, speaker-indep. pass
first_max_active=2000 # max-active used in initial pass.
alignment_model=
adapt_model=
final_model=
stage=0
acwt=0.083333 # Acoustic weight used in getting fMLLR transforms, and also in
              # lattice generation.
max_active=7000
beam=13.0
lattice_beam=6.0
nj=4
silence_weight=0.01
cmd=run.pl
si_dir=
fmllr_update_type=full
num_threads=1 # if >1, will use gmm-latgen-faster-parallel
parallel_opts=  # ignored now.
skip_scoring=false
scoring_opts=
max_fmllr_jobs=25  # I've seen the fMLLR jobs overload NFS badly if the decoding
                   # was started with a lot of many jobs, so we limit the number of
                   # parallel jobs to 25 by default.  End configuration section
echo "$0 $@"  # Print the command line for logging
set -x

[ -f ./path.sh ] && . ./path.sh; # source the path.
. parse_options.sh || exit 1;

if [ $# != 3 ]; then
   echo "Wrong #arguments ($#, expected 3)"
   echo "Usage: steps/decode_fmllr.sh [options] <graph-dir> <data-dir> <decode-dir>"
   echo " e.g.: steps/decode_fmllr.sh exp/tri2b/graph_tgpr data/test_dev93 exp/tri2b/decode_dev93_tgpr"
   echo "main options (for others, see top of script file)"
   echo "  --config <config-file>                   # config containing options"
   echo "  --nj <nj>                                # number of parallel jobs"
   echo "  --cmd <cmd>                              # Command to run in parallel with"
   echo "  --adapt-model <adapt-mdl>                # Model to compute transforms with"
   echo "  --alignment-model <ali-mdl>              # Model to get Gaussian-level alignments for"
   echo "                                           # 1st pass of transform computation."
   echo "  --final-model <finald-mdl>               # Model to finally decode with"
   echo "  --si-dir <speaker-indep-decoding-dir>    # use this to skip 1st pass of decoding"
   echo "                                           # Caution-- must be with same tree"
   echo "  --acwt <acoustic-weight>                 # default 0.08333 ... used to get posteriors"
   echo "  --num-threads <n>                        # number of threads to use, default 1."
   echo "  --scoring-opts <opts>                    # options to local/score.sh"
   exit 1;
fi


graphdir=$1
data=$2
dir=`echo $3 | sed 's:/$::g'` # remove any trailing slash.

srcdir=`dirname $dir`; # Assume model directory one level up from decoding directory.
sdata=$data/split$nj;

thread_string=
[ $num_threads -gt 1 ] && thread_string="-parallel --num-threads=$num_threads"


mkdir -p $dir/log
split_data.sh $data $nj || exit 1;
echo $nj > $dir/num_jobs
splice_opts=`cat $srcdir/splice_opts 2>/dev/null` # frame-splicing options.
cmvn_opts=`cat $srcdir/cmvn_opts 2>/dev/null`
delta_opts=`cat $srcdir/delta_opts 2>/dev/null`

silphonelist=`cat $graphdir/phones/silence.csl` || exit 1;

# Some checks.  Note: we don't need $srcdir/tree but we expect
# it should exist, given the current structure of the scripts.
for f in $graphdir/HCLG.fst $data/feats.scp $srcdir/tree; do
  [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
done

## Work out name of alignment model. ##
if [ -z "$alignment_model" ]; then
  if [ -f "$srcdir/final.alimdl" ]; then alignment_model=$srcdir/final.alimdl;
  else alignment_model=$srcdir/final.mdl; fi
fi
[ ! -f "$alignment_model" ] && echo "$0: no alignment model $alignment_model " && exit 1;
##

## Do the speaker-independent decoding, if --si-dir option not present. ##
if [ -z "$si_dir" ]; then # we need to do the speaker-independent decoding pass.
  si_dir=${dir}.si # Name it as our decoding dir, but with suffix ".si".
  if [ $stage -le 0 ]; then
    if [ -f "$graphdir/num_pdfs" ]; then
      [ "`cat $graphdir/num_pdfs`" -eq `am-info --print-args=false $alignment_model | grep pdfs | awk '{print $NF}'` ] || \
        { echo "Mismatch in number of pdfs with $alignment_model"; exit 1; }
    fi
    steps/decode.sh --scoring-opts "$scoring_opts" \
           --num-threads $num_threads --skip-scoring $skip_scoring \
           --acwt $acwt --nj $nj --cmd "$cmd" --beam $first_beam \
           --model $alignment_model --max-active \
           $first_max_active $graphdir $data $si_dir || exit 1;
  fi
fi
##

## Some checks, and setting of defaults for variables.
[ "$nj" -ne "`cat $si_dir/num_jobs`" ] && echo "Mismatch in #jobs with si-dir" && exit 1;
[ ! -f "$si_dir/lat.1.gz" ] && echo "No such file $si_dir/lat.1.gz" && exit 1;
[ -z "$adapt_model" ] && adapt_model=$srcdir/final.mdl
[ -z "$final_model" ] && final_model=$srcdir/final.mdl
for f in $adapt_model $final_model; do
  [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
done
##

## Set up the unadapted features "$sifeats"
if [ -f $srcdir/final.mat ]; then feat_type=lda; else feat_type=delta; fi
echo "$0: feature type is $feat_type";
case $feat_type in
  delta) sifeats="ark,s,cs:apply-cmvn $cmvn_opts --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:$sdata/JOB/feats.scp ark:- | add-deltas $delta_opts ark:- ark:- |";;
  lda) sifeats="ark,s,cs:apply-cmvn $cmvn_opts --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:$sdata/JOB/feats.scp ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $srcdir/final.mat ark:- ark:- |";;
  *) echo "Invalid feature type $feat_type" && exit 1;
esac
##

## Now get the first-pass fMLLR transforms.
if [ $stage -le 1 ]; then
  echo "$0: getting first-pass fMLLR transforms."
  $cmd --max-jobs-run $max_fmllr_jobs JOB=1:$nj $dir/log/fmllr_pass1.JOB.log \
    gunzip -c $si_dir/lat.JOB.gz \| \
    lattice-to-post --acoustic-scale=$acwt ark:- ark:- \| \
    weight-silence-post $silence_weight $silphonelist $alignment_model ark:- ark:- \| \
    gmm-post-to-gpost $alignment_model "$sifeats" ark:- ark:- \| \
    gmm-est-fmllr-gpost --fmllr-update-type=$fmllr_update_type \
    --spk2utt=ark:$sdata/JOB/spk2utt $adapt_model "$sifeats" ark,s,cs:- \
    ark:$dir/pre_trans.JOB || exit 1;
fi
##

pass1feats="$sifeats transform-feats --utt2spk=ark:$sdata/JOB/utt2spk ark:$dir/pre_trans.JOB ark:- ark:- |"

## Do the main lattice generation pass.  Note: we don't determinize the lattices at
## this stage, as we're going to use them in acoustic rescoring with the larger
## model, and it's more correct to store the full state-level lattice for this purpose.
if [ $stage -le 2 ]; then
  echo "$0: doing main lattice generation phase"
  if [ -f "$graphdir/num_pdfs" ]; then
    [ "`cat $graphdir/num_pdfs`" -eq `am-info --print-args=false $adapt_model | grep pdfs | awk '{print $NF}'` ] || \
      { echo "Mismatch in number of pdfs with $adapt_model"; exit 1; }
  fi
  $cmd --num-threads $num_threads JOB=1:$nj $dir/log/decode.JOB.log \
    gmm-latgen-faster$thread_string --max-active=$max_active --beam=$beam --lattice-beam=$lattice_beam \
    --acoustic-scale=$acwt --determinize-lattice=false \
    --allow-partial=true --word-symbol-table=$graphdir/words.txt \
    $adapt_model $graphdir/HCLG.fst "$pass1feats" "ark:|gzip -c > $dir/lat.tmp.JOB.gz" \
    || exit 1;
fi
##

## Do a second pass of estimating the transform-- this time with the lattices
## generated from the alignment model.  Compose the transforms to get
## $dir/trans.1, etc.
if [ $stage -le 3 ]; then
  echo "$0: estimating fMLLR transforms a second time."
  $cmd --max-jobs-run $max_fmllr_jobs JOB=1:$nj $dir/log/fmllr_pass2.JOB.log \
    lattice-determinize-pruned$thread_string --acoustic-scale=$acwt --beam=4.0 \
    "ark:gunzip -c $dir/lat.tmp.JOB.gz|" ark:- \| \
    lattice-to-post --acoustic-scale=$acwt ark:- ark:- \| \
    weight-silence-post $silence_weight $silphonelist $adapt_model ark:- ark:- \| \
    gmm-est-fmllr --fmllr-update-type=$fmllr_update_type \
    --spk2utt=ark:$sdata/JOB/spk2utt $adapt_model "$pass1feats" \
    ark,s,cs:- ark:$dir/trans_tmp.JOB '&&' \
    compose-transforms --b-is-affine=true ark:$dir/trans_tmp.JOB ark:$dir/pre_trans.JOB \
    ark:$dir/trans.JOB  || exit 1;
fi
##



feats="$sifeats transform-feats --utt2spk=ark:$sdata/JOB/utt2spk ark:$dir/trans.JOB ark:- ark:- |"

# Rescore the state-level lattices with the final adapted features, and the final model
# (which by default is $srcdir/final.mdl, but which may be specified on the command line,
# useful in case of discriminatively trained systems).
# At this point we prune and determinize the lattices and write them out, ready for
# language model rescoring.

if [ $stage -le 4 ]; then
  echo "$0: doing a final pass of acoustic rescoring."
  $cmd --num-threads $num_threads JOB=1:$nj $dir/log/acoustic_rescore.JOB.log \
    gmm-rescore-lattice $final_model "ark:gunzip -c $dir/lat.tmp.JOB.gz|" "$feats" ark:- \| \
    lattice-determinize-pruned$thread_string --acoustic-scale=$acwt --beam=$lattice_beam ark:- \
    "ark:|gzip -c > $dir/lat.JOB.gz" '&&' rm $dir/lat.tmp.JOB.gz || exit 1;
fi

if [ $stage -le 5 ]; then
  steps/diagnostic/analyze_lats.sh --cmd "$cmd" $graphdir $dir
fi

if ! $skip_scoring ; then
  [ ! -x local/score.sh ] && \
    echo "$0: not scoring because local/score.sh does not exist or not executable." && exit 1;
  local/score.sh $scoring_opts --cmd "$cmd" $data $graphdir $dir
fi

rm $dir/{trans_tmp,pre_trans}.*

exit 0;

