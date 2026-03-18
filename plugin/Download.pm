package Plugins::YouTubeDL::Download;

# Download handler for the YouTubeDL LMS plugin.
# Provides CLI/JSON-RPC commands for fire-and-forget yt-dlp downloads.
#
# CLI syntax (telnet / json-rpc):
#   youtube download url:<url>
#   youtube download log
#
# Accepted URL forms for <url>:
#   youtube://www.youtube.com/v/<id>       (LMS internal stream URL)
#   ytplaylist://playlistId=PL...          (LMS internal playlist URL)
#   ytplaylist://channelId=UC...           (LMS internal channel URL)
#   https://www.youtube.com/watch?v=<id>
#   https://youtu.be/<id>
#   https://www.youtube.com/playlist?list=PL...
#   https://music.youtube.com/playlist?list=PL...
#   https://www.youtube.com/channel/<id>
#   https://www.youtube.com/c/<name>
#
# Released under GPLv2

use strict;
use warnings;

use File::Spec;
use File::ReadBackwards;
use POSIX qw(O_RDONLY O_WRONLY O_CREAT O_APPEND strftime);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::OSDetect;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Network;

my $log   = logger('plugin.youtubedl');
my $prefs = preferences('plugin.youtubedl');


# ─────────────────────────────────────────────────────────────────────────────
# CLI command registration
# ─────────────────────────────────────────────────────────────────────────────

# Called from Plugin::initPlugin to wire up the CLI commands.
sub registerCLI {
	#        |requires Client
	#        |  |is a Query
	#        |  |  |has Tags
	#        |  |  |  |Function to call

	Slim::Control::Request::addDispatch(
		['youtube', 'download', 'log'],
		[0, 1, 1, \&cliDownloadLog],
	);

	Slim::Control::Request::addDispatch(
		['youtube', 'download'],
		[0, 0, 0, \&cliDownload],
	);

	$log->info('YouTubeDL: CLI commands registered (youtube download, youtube download log)');
}


# ─────────────────────────────────────────────────────────────────────────────
# CLI command handlers
# ─────────────────────────────────────────────────────────────────────────────

# CLI handler for "youtube download"
#   Positional:  ["youtube", "download", "<url>"]
#   Tagged:      youtube download url:<url>
sub cliDownload {
	my $request = shift;
	my $client  = $request->client();

	if ($request->isNotCommand([['youtube'], ['download']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# Accept both positional (_p2) and tagged (url:) parameter forms.
	my $url = $request->getParam('_p2') // $request->getParam('url');

	unless ($url) {
		$log->warn('youtube download: no URL supplied');
		$request->addResultLoop('item_loop', 0, 'text', cstring($client, 'PLUGIN_YOUTUBEDL_NO_URL'));
		$request->addResultLoop('item_loop', 0, 'type', 'text');
		$request->addResult('count',  1);
		$request->addResult('offset', 0);
		$request->setStatusDone();
		return;
	}

	my ($type, $id) = _parseUrl($url);

	unless ($type && $id) {
		$log->warn("youtube download: cannot parse URL '$url'");
		$request->addResultLoop('item_loop', 0, 'text', cstring($client, 'PLUGIN_YOUTUBEDL_BAD_URL'));
		$request->addResultLoop('item_loop', 0, 'type', 'text');
		$request->addResult('count',  1);
		$request->addResult('offset', 0);
		$request->setStatusDone();
		return;
	}

	my $result = startDownload($type, $id);

	my @items;
	if ($result->{pid}) {
		push @items, { type => 'text', name => cstring($client, 'PLUGIN_YOUTUBEDL_STARTED') };
		push @items, { type => 'text', name => $result->{url} } if $result->{url};
		push @items, {
			type => 'text',
			name => sprintf(cstring($client, 'PLUGIN_YOUTUBEDL_PID'), $result->{pid}),
		};
		push @items, {
			type => 'text',
			name => cstring($client, 'PLUGIN_YOUTUBEDL_FILES_SAVED_TO') . ' ' . _mediaFolder(),
		};
		push @items, {
			type    => 'link',
			name    => cstring($client, 'PLUGIN_YOUTUBEDL_VIEW_LOG'),
			weblink => Slim::Utils::Network::serverURL() . '/plugins/YouTubeDL/downloadlog.html',
		};
	} else {
		push @items, { type => 'text', name => cstring($client, 'PLUGIN_YOUTUBEDL_FAILED') };
		push @items, { type => 'text', name => $result->{url}     } if $result->{url};
		push @items, { type => 'text', name => $result->{message} } if $result->{message};
	}

	my $index = 0;
	for my $item (@items) {
		$request->addResultLoop('item_loop', $index, 'text',    $item->{name});
		$request->addResultLoop('item_loop', $index, 'type',    $item->{type});
		$request->addResultLoop('item_loop', $index, 'weblink', $item->{weblink}) if $item->{weblink};
		$index++;
	}
	$request->addResult('count',  $index);
	$request->addResult('offset', 0);
	$request->setStatusDone();
}

# CLI handler for "youtube download log"
# Returns the most recent yt-dlp log run as a menu item list.
sub cliDownloadLog {
	my $request = shift;
	my $client  = $request->client();

	my $title = $client
		? cstring($client, 'PLUGIN_YOUTUBEDL_LOG_TITLE')
		: string('PLUGIN_YOUTUBEDL_LOG_TITLE');
	$title ||= 'Download Log';
	$request->addResult('title', $title);

	my $logFile = _logFile();
	my @lines;

	if (-f $logFile) {
		open(my $fh, '<:encoding(UTF-8)', $logFile);
		@lines = <$fh>;
		close($fh);
		chomp @lines;

		# Find the last === separator === and show from there to EOF.
		my $last_sep = -1;
		for (my $i = $#lines; $i >= 0; $i--) {
			if ($lines[$i] =~ /^=== \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} ===/) {
				$last_sep = $i;
				last;
			}
		}

		if ($last_sep >= 0) {
			@lines = @lines[$last_sep .. $#lines];
		} else {
			my $start = $#lines - 50;
			$start = 0 if $start < 0;
			@lines = @lines[$start .. $#lines];
		}
	}

	my $index = 0;
	if (@lines) {
		for my $line (@lines) {
			utf8::encode($line) if utf8::is_utf8($line);
			$request->addResultLoop('item_loop', $index, 'text', $line);
			$request->addResultLoop('item_loop', $index, 'type', 'text');
			$index++;
		}
	} else {
		$request->addResultLoop('item_loop', 0, 'text', cstring($client, 'PLUGIN_YOUTUBEDL_LOG_EMPTY'));
		$request->addResultLoop('item_loop', 0, 'type', 'text');
		$index = 1;
	}

	$request->addResult('count',  $index);
	$request->addResult('offset', 0);
	$request->setStatusDone();
}


# ─────────────────────────────────────────────────────────────────────────────
# Download orchestration
# ─────────────────────────────────────────────────────────────────────────────

# Kick off a yt-dlp download.
#   $type  - 'video' or 'playlist'
#   $id    - video ID  or  raw query string (playlistId=..., channelId=...)
# Returns hashref { pid => <n or undef>, message => '...', url => '...' }
sub startDownload {
	my ($type, $id) = @_;

	my $binary = _ytdlpBinary();
	unless ($binary) {
		my $msg = 'yt-dlp binary not found — configure it in the YouTubeDL plugin settings';
		$log->error($msg);
		return { message => $msg };
	}

	my $ytUrl  = _buildYtUrl($type, $id);
	my $output = _outputTemplate($type);
	my @cmd    = _buildCommand($binary, $ytUrl, $output, $type);

	my $logFile = _logFile();
	$log->info("yt-dlp log: $logFile");
	$log->info('Starting yt-dlp: ' . join(' ', @cmd));

	my $result = main::ISWINDOWS
		? _launchWindows($logFile, @cmd)
		: _launchUnix($logFile, @cmd);

	if (defined $result->{pid}) {
		$log->info("Download started (pid $result->{pid}): $ytUrl");
		$result->{message} = 'Download started';
	} else {
		$log->error("Failed to launch yt-dlp for: $ytUrl");
		$result->{message} //= 'Failed to launch yt-dlp';
	}
	$result->{url} = $ytUrl;

	return $result;
}


# ─────────────────────────────────────────────────────────────────────────────
# Platform-specific process launchers
# ─────────────────────────────────────────────────────────────────────────────

# Linux / macOS: fork + exec, fully detached.
#
# We do NOT touch SIG{CHLD} — not even with 'local'.  LMS's AnyEvent loop
# uses an internal SIGCHLD watcher to detect when yt-dlp children started by
# ProtocolHandler::getNextTrack (via AnyEvent::Util::run_cmd) have exited.
# Clobbering that watcher leaves the playing playlist stuck between tracks.
#
# Zombie prevention: POSIX::setsid() makes the child a new session leader;
# when it exits, init (PID 1) reaps it — standard POSIX orphan behaviour.
#
# All fd manipulation uses raw POSIX calls because LMS ties STDIN/STDOUT/STDERR
# to Slim::Utils::Log::Trapper, which does not implement OPEN().  Perl's open()
# on a tied glob would call OPEN() and die.
sub _launchUnix {
	my ($logFile, @cmd) = @_;

	my $pid = fork();

	if (!defined $pid) {
		$log->error("fork() failed: $!");
		return { message => "fork() failed: $!" };
	}

	if ($pid == 0) {
		# ── child ──
		# $logFile was resolved in the parent; we never call LMS code here.

		# fd 0 → /dev/null
		my $null_fd = POSIX::open('/dev/null', O_RDONLY);
		POSIX::dup2($null_fd, 0) if defined $null_fd && $null_fd >= 0;
		POSIX::close($null_fd)   if defined $null_fd && $null_fd > 2;

		# fd 1 + 2 → log file, fallback chain to /tmp, /dev/null
		my $log_fd = POSIX::open($logFile, O_WRONLY | O_CREAT | O_APPEND, 0644);
		if (!defined $log_fd || $log_fd < 0) {
			$log_fd = POSIX::open('/tmp/yt-dlp-download.log',
				O_WRONLY | O_CREAT | O_APPEND, 0644);
		}
		if (!defined $log_fd || $log_fd < 0) {
			$log_fd = POSIX::open('/dev/null', O_WRONLY);
		}
		if (defined $log_fd && $log_fd >= 0) {
			my $ts = POSIX::strftime("\n=== %Y-%m-%d %H:%M:%S ===\n", localtime);
			POSIX::write($log_fd, $ts, length($ts));
			my $cl = join(' ', @cmd) . "\n";
			POSIX::write($log_fd, $cl, length($cl));
			POSIX::dup2($log_fd, 1);
			POSIX::dup2($log_fd, 2);
			POSIX::close($log_fd) if $log_fd > 2;
		}

		# Clean signal table so yt-dlp (PyInstaller) can waitpid() on ffmpeg.
		for my $sig (keys %SIG) {
			$SIG{$sig} = 'DEFAULT' if defined $SIG{$sig} && !ref $SIG{$sig};
		}

		POSIX::setsid();
		exec @cmd or POSIX::_exit(1);
	}

	# ── parent ──
	return { pid => $pid };
}

# Windows: Win32::Process::Create via cmd.exe, mirroring ProtocolHandler.
# fork()+exec() is unreliable on Windows Perl with LMS's tied stdio.
sub _launchWindows {
	my ($logFile, @cmd) = @_;

	eval { require Win32::Process } or do {
		$log->error("Win32::Process not available: $@");
		return { message => 'Win32::Process not available' };
	};

	my $cmdStr = join(' ', map { /\s/ ? qq{"$_"} : $_ } @cmd);
	$cmdStr .= ' >>' . qq{"$logFile"} . ' 2>&1';

	my $proc = 0;
	eval {
		Win32::Process::Create(
			$proc,
			$ENV{COMSPEC},
			"/c $cmdStr",
			0,    # do NOT inherit parent handles
			Win32::Process::NORMAL_PRIORITY_CLASS(),
			'.',
		);
	};

	if ($@) {
		$log->error("Win32::Process::Create failed: $@");
		return { message => "Process creation failed: $@" };
	}

	my $pid = eval { $proc->GetProcessID() } // 'unknown';
	return { pid => $pid };
}


# ─────────────────────────────────────────────────────────────────────────────
# Web log page handler
# ─────────────────────────────────────────────────────────────────────────────

sub webDownloadLog {
	my ($client, $params) = @_;

	my $content = getRecentLogContent();
	$content =~ s/&/&amp;/g;
	$content =~ s/</&lt;/g;
	$content =~ s/>/&gt;/g;

	return Slim::Web::HTTP::filltemplatefile(
		'plugins/YouTubeDL/html/downloadlog.html',
		{ content => Slim::Utils::Unicode::utf8encode($content) },
	);
}

# Returns the most recent download log session as a plain string.
sub getRecentLogContent {
	my $logFile = _logFile();
	return string('PLUGIN_YOUTUBEDL_LOG_EMPTY') unless -f $logFile;

	my $bw = File::ReadBackwards->new($logFile)
		or return string('PLUGIN_YOUTUBEDL_LOG_EMPTY');

	my @lines;
	my $found = 0;

	while (defined(my $line = $bw->readline)) {
		chomp $line;
		unshift @lines, $line;
		if ($line =~ /^=== \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} ===/) {
			$found = 1;
			last;
		}
		last if @lines > 1000;
	}
	$bw->close();

	if (!$found && @lines > 50) {
		@lines = @lines[-50 .. -1];
	}

	return join("\n", @lines) || string('PLUGIN_YOUTUBEDL_LOG_EMPTY');
}


# ─────────────────────────────────────────────────────────────────────────────
# URL helpers
# ─────────────────────────────────────────────────────────────────────────────

# Parse any supported URL form into ($type, $id).
sub _parseUrl {
	my ($url) = @_;

	# LMS internal video URL
	if ($url =~ m{^youtube://}i) {
		if ($url =~ m{^youtube://(?:(?:www|m)\.youtube\.com/v/)?([A-Za-z0-9_-]{11})(?:[^A-Za-z0-9_-]|$)}i) {
			return ('video', $1);
		}
	}

	# LMS internal playlist/channel URL
	if ($url =~ m{^ytplaylist://(.+)}i) {
		return ('playlist', $1);
	}

	# Raw https:// video
	if ($url =~ m{^https?://(?:(?:www|m|music)\.youtube\.com/watch\?.*v=|youtu\.be/)([A-Za-z0-9_-]{11})}i) {
		return ('video', $1);
	}

	# Raw https:// playlist
	if ($url =~ m{^https?://(?:(?:www|m|music)\.youtube\.com)/playlist\?.*list=([A-Za-z0-9_-]+)}i) {
		return ('playlist', "playlistId=$1");
	}

	# Raw https:// channel (canonical ID)
	if ($url =~ m{^https?://(?:(?:www|m)\.youtube\.com)/channel/([A-Za-z0-9_-]+)}i) {
		return ('playlist', "channelId=$1");
	}

	# Raw https:// channel (vanity / user URL)
	if ($url =~ m{^https?://(?:(?:www|m)\.youtube\.com)/(?:c|user)/([A-Za-z0-9_-]+)}i) {
		return ('playlist', "channelId=$1");
	}

	return (undef, undef);
}

# Convert ($type, $id) back to a canonical https:// URL for yt-dlp.
sub _buildYtUrl {
	my ($type, $id) = @_;

	return "https://www.youtube.com/watch?v=$id" if $type eq 'video';

	return "https://www.youtube.com/playlist?list=$1" if $id =~ /^playlistId=(.+)$/;
	return "https://www.youtube.com/channel/$1"       if $id =~ /^channelId=(.+)$/;

	return "https://www.youtube.com/$id";    # fallback
}

# Resolve the yt-dlp -o output template for the given type.
sub _outputTemplate {
	my ($type) = @_;

	my $base = _mediaFolder();

	if ($type eq 'video') {
		my $tpl = $prefs->get('download_output_video');
		if ($tpl) {
			return $tpl if File::Spec->file_name_is_absolute($tpl);
			return File::Spec->catfile($base, $tpl);
		}
		return File::Spec->catfile($base, 'YouTube', 'Singles', '%(uploader)s - %(title)s.%(ext)s');
	}

	# playlist / channel
	my $tpl = $prefs->get('download_output_playlist');
	if ($tpl) {
		return $tpl if File::Spec->file_name_is_absolute($tpl);
		return File::Spec->catfile($base, $tpl);
	}
	return File::Spec->catfile($base, 'YouTube', '%(playlist)s', '%(playlist_index)03d.%(title)s.%(ext)s');
}

# Build the full yt-dlp argument list.
sub _buildCommand {
	my ($binary, $ytUrl, $output, $type) = @_;

	my @cmd = (
		$binary,
		$ytUrl,
		'-x',
		'-o', $output,
		'-f', 'bestaudio',
		'--parse-metadata', 'playlist_index:%(track_number)s',
		'--parse-metadata', '%(release_date,upload_date)s:(?P<meta_date>[0-9]{4})',
		'--embed-metadata',
		'--embed-thumbnail',
		'--convert-thumbnails', 'jpg',
		'--postprocessor-args',
			'ThumbnailsConvertor:-vf scale=500:500:force_original_aspect_ratio=increase,crop=500:500',
	);

	# Add --ffmpeg-location if the user has configured a custom path.
	my $ffmpeg = $prefs->get('ffmpeg_path');
	if ($ffmpeg && -e $ffmpeg) {
		push @cmd, '--ffmpeg-location', $ffmpeg;
	}

	push @cmd, '--no-abort-on-error' if $type eq 'playlist';

	return @cmd;
}


# ─────────────────────────────────────────────────────────────────────────────
# Path helpers
# ─────────────────────────────────────────────────────────────────────────────

# Locate the yt-dlp binary.
# Preference order:
#   1. plugin pref 'yt_dlp' (custom path entered in YouTubeDL settings)
#   2. YouTube plugin pref 'yt_dlp' resolved via YouTube's Utils::yt_dlp_bin()
#   3. 'yt-dlp' on PATH
sub _ytdlpBinary {
	# 1. Custom path set in our own settings.
	my $custom = $prefs->get('yt_dlp');
	if ($custom && $custom ne '' && -x $custom) {
		return $custom;
	}

	# 2. Delegate to the YouTube plugin's Utils if available.
	#    That function resolves a bare filename like "yt-dlp_linux" against the
	#    YouTube plugin's Bin/ directory, producing the correct full path.
	my $ytdlp = eval {
		require Plugins::YouTube::Utils;
		my $yt_prefs = preferences('plugin.youtube');
		Plugins::YouTube::Utils::yt_dlp_bin( $yt_prefs->get('yt_dlp') );
	};
	return $ytdlp if $ytdlp && -x $ytdlp;

	# 3. Fall back to whatever is on PATH.
	for my $candidate (qw(yt-dlp yt-dlp_linux yt-dlp_macos)) {
		my $found = Slim::Utils::OSDetect::getOS()->which($candidate);
		return $found if $found && -x $found;
	}

	return undef;
}

# Resolve the media folder root.
sub _mediaFolder {
	my $custom = $prefs->get('download_media_folder');
	return $custom if $custom && -d $custom;

	my $sp   = preferences('server');
	my $dirs = $sp->get('audiodir') // $sp->get('mediadirs');

	if (ref $dirs eq 'ARRAY') {
		return $dirs->[0] if @$dirs;
	} elsif ($dirs) {
		return $dirs;
	}

	return (Slim::Utils::OSDetect::dirsFor('music'))[0] // '.';
}

# Path to the plugin's dedicated yt-dlp download log.
sub _logFile {
	my ($logDir) = Slim::Utils::OSDetect::dirsFor('log');
	return File::Spec->catfile($logDir, 'yt-dlp-download.log');
}

1;
