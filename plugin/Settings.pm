package Plugins::YouTubeDL::Settings;

use base qw(Slim::Web::Settings);

use strict;

use File::Spec;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

my $log   = logger('plugin.youtubedl');
my $prefs = preferences('plugin.youtubedl');

sub name { 'PLUGIN_YOUTUBEDL' }

sub page { 'plugins/YouTubeDL/settings/basic.html' }

sub prefs {
	return (
		preferences('plugin.youtubedl'),
		qw(
			yt_dlp
			ffmpeg_path
			download_media_folder
			download_output_playlist
			download_output_video
		),
	);
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	# ── yt-dlp binary ──────────────────────────────────────────────────────────
	if ($params->{saveSettings} && defined $params->{pref_yt_dlp}) {
		my $path = _cleanPath($params->{pref_yt_dlp});
		$params->{pref_yt_dlp} = $path;
	}

	# Show status of the configured (or auto-detected) yt-dlp binary.
	{
		require Plugins::YouTubeDL::Download;
		my $resolved = Plugins::YouTubeDL::Download::_ytdlpBinary(
			$params->{saveSettings} ? $params->{pref_yt_dlp} : undef
		);

		if ($resolved && -f $resolved) {
			$params->{ytdlp_status} = 'ok';
			$params->{ytdlp_msg}    = string('PLUGIN_YOUTUBEDL_BINARY_FOUND') . ': ' . $resolved;
		} else {
			$params->{ytdlp_status} = 'error';
			$params->{ytdlp_msg}    = string('PLUGIN_YOUTUBEDL_BINARY_NOT_FOUND');
		}
	}

	# ── ffmpeg ─────────────────────────────────────────────────────────────────
	if ($params->{saveSettings} && defined $params->{pref_ffmpeg_path}) {
		my $path = _cleanPath($params->{pref_ffmpeg_path});
		$params->{pref_ffmpeg_path} = $path;
	}

	{
		# Use the just-submitted value if saving, otherwise the stored pref.
		my $ffmpeg = $params->{saveSettings}
			? $params->{pref_ffmpeg_path}
			: $prefs->get('ffmpeg_path');

		if ($ffmpeg && $ffmpeg ne '') {
			if (-f $ffmpeg) {
				$params->{ffmpeg_status} = 'ok';
				$params->{ffmpeg_msg}    = string('PLUGIN_YOUTUBEDL_BINARY_FOUND') . ': ' . $ffmpeg;
			} else {
				$params->{ffmpeg_status} = 'error';
				$params->{ffmpeg_msg}    = string('PLUGIN_YOUTUBEDL_BINARY_NOT_FOUND');
			}
		} else {
			my $found = _whichFfmpeg();
			if ($found) {
				$params->{ffmpeg_status} = 'ok';
				$params->{ffmpeg_msg}    = string('PLUGIN_YOUTUBEDL_FFMPEG_SYSTEM') . ': ' . $found;
			} else {
				$params->{ffmpeg_status} = 'error';
				$params->{ffmpeg_msg}    = string('PLUGIN_YOUTUBEDL_FFMPEG_NOT_FOUND');
			}
		}
	}

	# ── media folder ───────────────────────────────────────────────────────────
	if ($params->{saveSettings}) {
		my $folder = $params->{pref_download_media_folder};
		if (defined $folder) {
			$folder = _cleanPath($folder);
			$params->{pref_download_media_folder} = $folder;
		}

		if (defined $folder && $folder ne '') {
			my ($status, $msg);
			if (!-d $folder) {
				$status = 'error';
				$msg    = string('PLUGIN_YOUTUBEDL_FOLDER_NOT_FOUND');
			} else {
				# -w is unreliable on Windows; probe with a real file create.
				my $probe = File::Spec->catfile($folder, '.ytdl_write_test_' . $$);
				if (open(my $fh, '>', $probe)) {
					close($fh);
					unlink($probe);
					$status = 'ok';
					$msg    = string('PLUGIN_YOUTUBEDL_FOLDER_OK');
				} else {
					$status = 'error';
					$msg    = string('PLUGIN_YOUTUBEDL_FOLDER_NOT_WRITABLE');
				}
			}
			$params->{folder_status} = $status;
			$params->{folder_msg}    = $msg;
			$log->info("Media folder check '$folder': $status");
		}
	}

	$callback->($client, $params, $class->SUPER::handler($client, $params), @args);
}


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

# Normalise a path value pasted from a terminal or file manager.
sub _cleanPath {
	my ($p) = @_;
	return '' unless defined $p;
	$p =~ s/^\s+|\s+$//g;             # strip surrounding whitespace
	$p =~ s/^(['"])(.*)\1$/$2/;       # strip surrounding quotes
	$p =~ s/\\ / /g;                  # unescape backslash-spaces
	return $p;
}

# Try to find ffmpeg on the system PATH.
sub _whichFfmpeg {
	# Check the same directory as the yt-dlp binary first.
	my $ytdlp = eval { Plugins::YouTubeDL::Download::_ytdlpBinary() };
	if ($ytdlp) {
		my $dir      = (File::Spec->splitpath($ytdlp))[1];
		my $ffmpeg   = File::Spec->catfile($dir, 'ffmpeg');
		my $ffmpegex = File::Spec->catfile($dir, 'ffmpeg.exe');
		return $ffmpeg   if -f $ffmpeg;
		return $ffmpegex if -f $ffmpegex;
	}

	# Check PATH.
	for my $name (qw(ffmpeg ffmpeg.exe)) {
		my $found = eval { Slim::Utils::OSDetect::getOS()->which($name) };
		return $found if $found && -f $found;
	}

	# Hardcoded Unix locations.
	for my $path (qw(/usr/bin/ffmpeg /usr/local/bin/ffmpeg /opt/homebrew/bin/ffmpeg)) {
		return $path if -f $path;
	}

	return undef;
}

1;
