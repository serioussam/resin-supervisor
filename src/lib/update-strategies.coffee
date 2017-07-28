logTypes = require './log-types'
{ checkTruthy, checkInt } = require './validation'

module.exports = class UpdateStrategies
	constructor: (@application) ->

	fetchOptions: (app) =>
		@application.config.getMany([ 'uuid', 'currentApiKey', 'apiEndpoint', 'deltaEndpoint' ])
		.then ({ uuid, currentApiKey, apiEndpoint, deltaEndpoint }) ->
			return {
				uuid
				apiKey: currentApiKey
				apiEndpoint
				deltaEndpoint
				delta: checkTruthy(app.config['RESIN_SUPERVISOR_DELTA'])
				deltaRequestTimeout: checkInt(app.config['RESIN_SUPERVISOR_DELTA_REQUEST_TIMEOUT'], positive: true) ? 30 * 60 * 1000
				deltaTotalTimeout: checkInt(app.config['RESIN_SUPERVISOR_DELTA_TOTAL_TIMEOUT'], positive: true) ? 24 * 60 * 60 * 1000
			}

	'download-then-kill': ({ localApp, app, needsDownload, force }) =>
		Promise.try =>
			if needsDownload
				@fetchOptions(app)
				.then (opts) =>
					@application.images.fetch(app.image, app, opts)
		.then =>
			Promise.using @application.lockUpdates(localApp, force), =>
				@application.logger.logSystemEvent(logTypes.updateApp, app) if localApp.image == app.image
				@application.containers.killByApp(localApp)
				.then =>
					@application.containers.startByApp(app)
			.catch (err) =>
				@application.logger.logSystemEvent(logTypes.updateAppError, app, err) unless err instanceof @application.UpdatesLockedError
				throw err
	'kill-then-download': ({ localApp, app, needsDownload, force }) =>
		Promise.using @application.lockUpdates(localApp, force), =>
			@application.logger.logSystemEvent(logTypes.updateApp, app) if localApp.image == app.image
			@application.containers.killByApp(localApp)
			.then =>
				if needsDownload
					@fetchOptions(app)
					.then (opts) =>
						@application.images.fetch(app.image, app, opts)
			.then =>
				@application.containers.startByApp(app)
		.catch (err) =>
			@application.logger.logSystemEvent(logTypes.updateAppError, app, err) unless err instanceof @application.UpdatesLockedError
			throw err
	'delete-then-download': ({ localApp, app, needsDownload, force }) =>
		Promise.using @application.lockUpdates(localApp, force), =>
			@application.logger.logSystemEvent(logTypes.updateApp, app) if localApp.image == app.image
			@application.containers.killByApp(localApp)
			.then =>
				# If we don't need to download a new image,
				# there's no use in deleting the image
				if needsDownload
					@application.images.remove(localApp.image, localApp)
					.then =>
						@fetchOptions(app)
					.then (opts) =>
						@application.images.fetch(app.image, app, opts)
			.then =>
				@application.containers.startByApp(app)
		.catch (err) =>
			@application.logger.logSystemEvent(logTypes.updateAppError, app, err) unless err instanceof @application.UpdatesLockedError
			throw err
	'hand-over': ({ localApp, app, needsDownload, force, timeout }) ->
		Promise.using @application.lockUpdates(localApp, force), ->
			Promise.try =>
				if needsDownload
					@fetchOptions(app)
					.then (opts) =>
						@application.images.fetch(app.image, app, opts)
			.then =>
				@application.logger.logSystemEvent(logTypes.updateApp, app) if localApp.image == app.image
				@application.containers.startByApp(app)
			.then =>
				@application.containers.waitToKillByApp(localApp, timeout)
			.then =>
				@application.containers.killByApp(localApp)
		.catch (err) =>
			@application.logger.logSystemEvent(logTypes.updateAppError, app, err) unless err instanceof @application.UpdatesLockedError
			throw err
