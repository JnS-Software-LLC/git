#!/usr/bin/env perl
# Copyright (c) 2009, 2010 David Aguilar
# Copyright (c) 2012 Tim Henigan
#
# This is a wrapper around the GIT_EXTERNAL_DIFF-compatible
# git-difftool--helper script.
#
# This script exports GIT_EXTERNAL_DIFF and GIT_PAGER for use by git.
# GIT_DIFFTOOL_NO_PROMPT, GIT_DIFFTOOL_PROMPT, GIT_DIFFTOOL_DIRDIFF,
# and GIT_DIFF_TOOL are exported for use by git-difftool--helper.
#
# Any arguments that are unknown to this script are forwarded to 'git diff'.

use 5.008;
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Copy;
use File::stat;
use File::Path qw(mkpath);
use File::Temp qw(tempdir);
use Getopt::Long qw(:config pass_through);
use Git;

sub usage
{
	my $exitcode = shift;
	print << 'USAGE';
usage: git difftool [-t|--tool=<tool>] [-x|--extcmd=<cmd>]
                    [-y|--no-prompt]   [-g|--gui]
                    [-d|--dir-diff]
                    ['git diff' options]
USAGE
	exit($exitcode);
}

sub setup_dir_diff
{
	# Run the diff; exit immediately if no diff found
	my $repo = Git->repository();
	my $diffrtn = $repo->command_oneline(['diff', '--raw', '--no-abbrev', '-z', @ARGV]);
	exit(0) if (length($diffrtn) == 0);

	# Setup temp directories
	my $tmpdir = tempdir('git-diffall.XXXXX', CLEANUP => 1, TMPDIR => 1);
	my $ldir = "$tmpdir/left";
	my $rdir = "$tmpdir/right";
	mkpath($ldir) or die $!;
	mkpath($rdir) or die $!;

	# Build index info for left and right sides of the diff
	my $submodule_mode = "160000";
	my $null_mode = 0 x 6;
	my $null_sha1 = 0 x 40;
	my $lindex = "";
	my $rindex = "";
	my @working_tree;
	my %submodule;
	my @rawdiff = split('\0', $diffrtn);

	for (my $i=0; $i<@rawdiff; $i+=2) {
		my ($lmode, $rmode, $lsha1, $rsha1, $status) = split(' ', substr($rawdiff[$i], 1));
		my $path = $rawdiff[$i + 1];

		if (($lmode eq $submodule_mode) or ($rmode eq $submodule_mode)) {
			$submodule{$path}{left} = $lsha1;
			$submodule{$path}{right} = $rsha1;
			next;
		}

		if ($lmode ne $null_mode) {
			$lindex .= "$lmode $lsha1\t$path\0";
		}

		if ($rmode ne $null_mode) {
			if ($rsha1 ne $null_sha1) {
				$rindex .= "$rmode $rsha1\t$path\0";
			} else {
				push(@working_tree, $path);
			}
		}
	}

	# Populate the left and right directories based on each index file
	my ($inpipe, $ctx);
	$ENV{GIT_INDEX_FILE} = "$tmpdir/lindex";
	($inpipe, $ctx) = $repo->command_input_pipe(qw/update-index -z --index-info/);
	print($inpipe $lindex);
	$repo->command_close_pipe($inpipe, $ctx);
	$repo->command_oneline(["checkout-index", "-a", "--prefix=$ldir/"]);

	$ENV{GIT_INDEX_FILE} = "$tmpdir/rindex";
	($inpipe, $ctx) = $repo->command_input_pipe(qw/update-index -z --index-info/);
	print($inpipe $rindex);
	$repo->command_close_pipe($inpipe, $ctx);
	$repo->command_oneline(["checkout-index", "-a", "--prefix=$rdir/"]);

	# Changes in the working tree need special treatment since they are
	# not part of the index
	my $workdir = $repo->wc_path();
	for (@working_tree) {
		my $dir = dirname($_);
		unless (-d "$rdir/$dir") {
			mkpath("$rdir/$dir") or die $!;
		}
		copy("$workdir/$_", "$rdir/$_") or die $!;
		chmod(stat("$workdir/$_")->mode, "$rdir/$_") or die $!;
	}

	# Changes to submodules require special treatment. This loop writes a
	# temporary file to both the left and right directories to show the
	# change in the recorded SHA1 for the submodule.
	foreach my $path (keys %submodule) {
		if (defined $submodule{$path}{left}) {
			open(my $fh, ">", "$ldir/$path") or die $!;
			print($fh "Subproject commit $submodule{$path}{left}");
			close($fh);
		}
		if (defined $submodule{$path}{right}) {
			open(my $fh, ">", "$rdir/$path") or die $!;
			print($fh "Subproject commit $submodule{$path}{right}");
			close($fh);
		}
	}

	return ($ldir, $rdir);
}

# parse command-line options. all unrecognized options and arguments
# are passed through to the 'git diff' command.
my ($difftool_cmd, $dirdiff, $extcmd, $gui, $help, $no_prompt, $prompt);
GetOptions('g|gui' => \$gui,
	'd|dir-diff' => \$dirdiff,
	'h' => \$help,
	'prompt' => \$prompt,
	't|tool:s' => \$difftool_cmd,
	'x|extcmd:s' => \$extcmd,
	'y|no-prompt' => \$no_prompt);

if (defined($help)) {
	usage(0);
}
if (defined($difftool_cmd)) {
	if (length($difftool_cmd) > 0) {
		$ENV{GIT_DIFF_TOOL} = $difftool_cmd;
	} else {
		print "No <tool> given for --tool=<tool>\n";
		usage(1);
	}
}
if (defined($extcmd)) {
	if (length($extcmd) > 0) {
		$ENV{GIT_DIFFTOOL_EXTCMD} = $extcmd;
	} else {
		print "No <cmd> given for --extcmd=<cmd>\n";
		usage(1);
	}
}
if (defined($gui)) {
	my $guitool = "";
	$guitool = Git::config('diff.guitool');
	if (length($guitool) > 0) {
		$ENV{GIT_DIFF_TOOL} = $guitool;
	}
}

# In directory diff mode, 'git-difftool--helper' is called once
# to compare the a/b directories.  In file diff mode, 'git diff'
# will invoke a separate instance of 'git-difftool--helper' for
# each file that changed.
if (defined($dirdiff)) {
	my ($a, $b) = setup_dir_diff();
	if (defined($extcmd)) {
		system(($extcmd, $a, $b));
	} else {
		$ENV{GIT_DIFFTOOL_DIRDIFF} = 'true';
		git_cmd_try {
			Git::command_noisy(('difftool--helper', $a, $b))
		} 'exit code %d';
	}
	# TODO: if the diff including working copy files and those
	# files were modified during the diff, then the changes
	# should be copied back to the working tree
} else {
	if (defined($prompt)) {
		$ENV{GIT_DIFFTOOL_PROMPT} = 'true';
	}
	elsif (defined($no_prompt)) {
		$ENV{GIT_DIFFTOOL_NO_PROMPT} = 'true';
	}

	$ENV{GIT_PAGER} = '';
	$ENV{GIT_EXTERNAL_DIFF} = 'git-difftool--helper';
	git_cmd_try { Git::command_noisy(('diff', @ARGV)) } 'exit code %d';
}
