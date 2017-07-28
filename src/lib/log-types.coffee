module.exports =
	stopService:
		eventName: 'Service kill'
		humanName: 'Killing service'
	stopServiceSuccess:
		eventName: 'Service stop'
		humanName: 'Killed service'
	stopServiceNoop:
		eventName: 'Service already stopped'
		humanName: 'Service is already stopped, removing container'
	stopRemoveServiceNoop:
		eventName: 'Service already stopped and container removed'
		humanName: 'Service is already stopped and the container removed'
	stopServiceError:
		eventName: 'Service stop error'
		humanName: 'Failed to kill service'

	downloadService:
		eventName: 'Service docker download'
		humanName: 'Downloading service'
	downloadServiceDelta:
		eventName: 'Service delta download'
		humanName: 'Downloading delta for service'
	downloadServiceSuccess:
		eventName: 'Service downloaded'
		humanName: 'Downloaded service'
	downloadServiceError:
		eventName: 'Service download error'
		humanName: 'Failed to download service'

	installService:
		eventName: 'Service install'
		humanName: 'Installing service'
	installServiceSuccess:
		eventName: 'Service installed'
		humanName: 'Installed service'
	installServiceError:
		eventName: 'Service install error'
		humanName: 'Failed to install service'

	deleteImageForService:
		eventName: 'Service image removal'
		humanName: 'Deleting image for service'
	deleteImageForServiceSuccess:
		eventName: 'Service image removed'
		humanName: 'Deleted image for service'
	deleteImageForServiceError:
		eventName: 'Service image removal error'
		humanName: 'Failed to delete image for service'
	imageAlreadyDeleted:
		eventName: 'Image already deleted'
		humanName: 'Image already deleted for service'

	startService:
		eventName: 'Service start'
		humanName: 'Starting service'
	startServiceSuccess:
		eventName: 'Service started'
		humanName: 'Started service'
	startServiceNoop:
		eventName: 'Service already running'
		humanName: 'Service is already running'
	startServiceError:
		eventName: 'Service start error'
		humanName: 'Failed to start service'

	updateService:
		eventName: 'Service update'
		humanName: 'Updating service'
	updateServiceError:
		eventName: 'Service update error'
		humanName: 'Failed to update service'

	serviceExit:
		eventName: 'Service exit'
		humanName: 'Service exited'

	serviceRestart:
		eventName: 'Service restart'
		humanName: 'Restarting service'

	updateServiceConfig:
		eventName: 'Service config update'
		humanName: 'Updating config for service'
	updateServiceConfigSuccess:
		eventName: 'Service config updated'
		humanName: 'Updated config for service'
	updateServiceConfigError:
		eventName: 'Service config update error'
		humanName: 'Failed to update config for service'

	volumeCreate:
		eventName: 'Volume creation'
		humanName: 'Creating volume'

	volumeCreateError:
		eventName: 'Volume creation error'
		humanName: 'Error creating volume'

	volumeRemove:
		eventName: 'Volume removal'
		humanName: 'Removing volume'

	volumeRemoveError:
		eventName: 'Volume removal error'
		humanName: 'Error removing volume'

	networkCreate:
		eventName: 'Network creation'
		humanName: 'Creating network'

	networkCreateError:
		eventName: 'Network creation error'
		humanName: 'Error creating network'

	networkRemove:
		eventName: 'Network removal'
		humanName: 'Removing network'

	networkRemoveError:
		eventName: 'Network removal error'
		humanName: 'Error removing network'