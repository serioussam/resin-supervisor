logTypes = require './log-types'
{ checkTruthy, checkInt } = require './validation'
updateLock = require './update-lock'
{ dataPath } = require './conversions'

module.exports = class UpdateStrategies
	constructor: (@containers, @images, @logger) ->

	killmePath: (service) =>
		return "#{dataPath(service)}/resin-kill-me"

	fetchOptions: (target, { uuid, currentApiKey, apiEndpoint, deltaEndpoint }) =>
		return {
			uuid
			apiKey: currentApiKey
			apiEndpoint
			deltaEndpoint
			delta: checkTruthy(target.config['RESIN_SUPERVISOR_DELTA'])
			deltaRequestTimeout: checkInt(target.config['RESIN_SUPERVISOR_DELTA_REQUEST_TIMEOUT'], positive: true) ? 30 * 60 * 1000
			deltaTotalTimeout: checkInt(target.config['RESIN_SUPERVISOR_DELTA_TOTAL_TIMEOUT'], positive: true) ? 24 * 60 * 60 * 1000
		}

	progressReportFn: (reportProgress, target) ->
		_.partial(reportProgress, target.serviceId)

	'download-then-kill': ({ current, target, needsDownload, force, lock, reportProgress }) =>
		Promise.try =>
			if needsDownload
				@fetchOptions(target)
				.then (opts) =>
					@images.fetch(target.image, target, opts, progressReportFn(reportProgress, target))
		.then =>
			Promise.using updateLock.lock(current.appId, { force }), =>
				@logger.logSystemEvent(logTypes.updateApp, target) if current.image == target.image
				@containers.kill(current)
				.then =>
					@containers.start(target)
			.catch (err) =>
				@logger.logSystemEvent(logTypes.updateAppError, target, err) unless err instanceof updateLock.UpdatesLockedError
				throw err
	'kill-then-download': ({ current, target, needsDownload, force, lock, reportProgress }) =>
		Promise.using updateLock.lock(current.appId, { force }), =>
			@logger.logSystemEvent(logTypes.updateApp, target) if current.image == target.image
			@containers.kill(current)
			.then =>
				if needsDownload
					@fetchOptions(target)
					.then (opts) =>
						@images.fetch(target.image, target, opts)
			.then =>
				@containers.start(target)
		.catch (err) =>
			@logger.logSystemEvent(logTypes.updateAppError, target, err) unless err instanceof updateLock.UpdatesLockedError
			throw err
	'delete-then-download': ({ current, target, needsDownload, force, lock, reportProgress }) =>
		Promise.using updateLock.lock(current.appId, { force }), =>
			@logger.logSystemEvent(logTypes.updateApp, target) if current.image == target.image
			@containers.kill(current)
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
				@containers.start(target)
		.catch (err) =>
			@logger.logSystemEvent(logTypes.updateAppError, target, err) unless err instanceof updateLock.UpdatesLockedError
			throw err
	'hand-over': ({ current, target, needsDownload, force, lock, reportProgress, timeout }) ->
		Promise.using updateLock.lock(current.appId, { force }), ->
			Promise.try =>
				if needsDownload
					@fetchOptions(target)
					.then (opts) =>
						@images.fetch(target.image, target, opts)
			.then =>
				@logger.logSystemEvent(logTypes.updateApp, target) if current.image == target.image
				@containers.start(target)
			.then =>
				@waitToKill(current, timeout)
			.then =>
				@containers.kill(current)
		.catch (err) =>
			@logger.logSystemEvent(logTypes.updateAppError, target, err) unless err instanceof updateLock.UpdatesLockedError
			throw err

	# TODO: move to update-strategies?
	# Wait for app to signal it's ready to die, or timeout to complete.
	# timeout defaults to 1 minute.
	waitToKill: (service, timeout) =>
		startTime = Date.now()
		pollInterval = 100
		timeout = checkInt(timeout, positive: true) ? 60000
		checkFileOrTimeout = =>
			fs.statAsync(@killmePath(service))
			.catch (err) ->
				throw err unless (Date.now() - startTime) > timeout
			.then =>
				fs.unlinkAsync(@killmePath(service)).catch(_.noop)
		# We've seen bluebird bugs with recursive promise chains,
		# so instead we use our own setImmediate to clear the stack in every call
		new Promise (resolve) ->
			retryCheck = ->
				checkFileOrTimeout()
				.then(resolve)
				.catch ->
					Promise.delay(pollInterval).then ->
						setImmediate(retryCheck)
			retryCheck()
