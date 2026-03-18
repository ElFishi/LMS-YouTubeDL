package Plugins::YouTubeDL::Plugin;

# YouTubeDL - LMS plugin providing CLI/JSON-RPC download commands for YouTube
# content via yt-dlp. Intended as a companion to the YouTube plugin by Philippe,
# reusing its yt-dlp binary and prefs where available.
#
# CLI syntax (telnet / json-rpc):
#   youtube download url:<url>
#   youtube download log
#
# Released under GPLv2

use strict;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::YouTubeDL::Download;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.youtubedl',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_YOUTUBEDL',
});

my $prefs = preferences('plugin.youtubedl');

$prefs->init({
	yt_dlp                   => '',
	ffmpeg_path              => '',
	download_media_folder    => '',
	download_output_playlist => '',
	download_output_video    => '',
});

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(@_);

	if ( main::WEBUI ) {
		require Plugins::YouTubeDL::Settings;
		Plugins::YouTubeDL::Settings->new;

		Slim::Web::Pages->addPageFunction(
			'plugins/YouTubeDL/downloadlog.html',
			\&Plugins::YouTubeDL::Download::webDownloadLog,
		);
	}

	Plugins::YouTubeDL::Download::registerCLI();

	$log->info('YouTubeDL plugin initialised');
}

sub shutdownPlugin {}

sub getDisplayName { 'PLUGIN_YOUTUBEDL' }

1;
