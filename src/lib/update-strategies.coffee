logTypes = require './log-types'
{ checkTruthy, checkInt } = require './validation'

module.exports = class UpdateStrategies
	constructor: (@application, @containers, @images, @logger) ->

	fetchOptions: (target) =>
		@application.config.getMany([ 'uuid', 'currentApiKey', 'apiEndpoint', 'deltaEndpoint' ])
		.then ({ uuid, currentApiKey, apiEndpoint, deltaEndpoint }) ->
			return {
				uuid
				apiKey: currentApiKey
				apiEndpoint
				deltaEndpoint
				delta: checkTruthy(target.config['RESIN_SUPERVISOR_DELTA'])
				deltaRequestTimeout: checkInt(target.config['RESIN_SUPERVISOR_DELTA_REQUEST_TIMEOUT'], positive: true) ? 30 * 60 * 1000
				deltaTotalTimeout: checkInt(target.config['RESIN_SUPERVISOR_DELTA_TOTAL_TIMEOUT'], positive: true) ? 24 * 60 * 60 * 1000
			}

	progressReportFn: (target) ->
		return (state) =>
			@application.reportServiceStatus(target.serviceId, state)

	'download-then-kill': ({ current, target, needsDownload, force }) =>
		Promise.try =>
			if needsDownload
				@fetchOptions(target)
				.then (opts) =>
					@images.fetch(target.image, target, opts, progressReportFn(target))
		.then =>
			Promise.using @application.lockUpdates(current, force), =>
				@logger.logSystemEvent(logTypes.updateApp, target) if current.image == target.image
				@containers.killByApp(current)
				.then =>
					@containers.startByApp(target)
			.catch (err) =>
				@logger.logSystemEvent(logTypes.updateAppError, target, err) unless err instanceof @application.UpdatesLockedError
				throw err
	'kill-then-download': ({ current, target, needsDownload, force }) =>
		Promise.using @application.lockUpdates(current, force), =>
			@logger.logSystemEvent(logTypes.updateApp, target) if current.image == target.image
			@containers.killByApp(current)
			.then =>
				if needsDownload
					@fetchOptions(target)
					.then (opts) =>
						@images.fetch(target.image, target, opts)
			.then =>
				@containers.startByApp(target)
		.catch (err) =>
			@logger.logSystemEvent(logTypes.updateAppError, target, err) unless err instanceof @application.UpdatesLockedError
			throw err
	'delete-then-download': ({ current, target, needsDownload, force }) =>
		Promise.using @application.lockUpdates(current, force), =>
			@logger.logSystemEvent(logTypes.updateApp, target) if current.image == target.image
			@containers.killByApp(current)
			.then =>
				# If we don't need to download a new image,
				# there's no use in deleting the image
				if needsDownload
					@images.remove(current.image, current)
					.then =>
						@fetchOptions(target)
					.then (opts) =>
						@images.fetch(target.image, target, opts)
			.then =>
				@containers.startByApp(target)
		.catch (err) =>
			@logger.logSystemEvent(logTypes.updateAppError, target, err) unless err instanceof @application.UpdatesLockedError
			throw err
	'hand-over': ({ current, target, needsDownload, force, timeout }) ->
		Promise.using @application.lockUpdates(current, force), ->
			Promise.try =>
				if needsDownload
					@fetchOptions(target)
					.then (opts) =>
						@images.fetch(target.image, target, opts)
			.then =>
				@logger.logSystemEvent(logTypes.updateApp, target) if current.image == target.image
				@containers.startByApp(target)
			.then =>
				@containers.waitToKillByApp(current, timeout)
			.then =>
				@containers.killByApp(current)
		.catch (err) =>
			@logger.logSystemEvent(logTypes.updateAppError, target, err) unless err instanceof @application.UpdatesLockedError
			throw err
