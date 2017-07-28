Promise = require 'bluebird'
_ = require 'lodash'
logTypes = require './lib/log-types'
constants = require './lib/constants'

ImageNotFoundError = (err) ->
	return "#{err.statusCode}" is '404'

module.exports = class Images
	constructor: ({ @docker, @logger, @reportServiceStatus, @db, @modelName }) ->

	fetch: (imageName, service = {}, opts) =>
		onProgress = (progress) =>
			@reportServiceStatus(service.serviceId, { download_progress: progress.percentage }) if service.serviceId?

		@get(imageName)
		.catch (error) =>
			@docker.normaliseImageName(imageName)
			.then (image) =>
				@reportServiceStatus(service.serviceId, { status: 'Downloading', download_progress: 0 }) if service.serviceId?
				@markAsSupervised(image)
				.then =>
					if opts.delta
						@logger.logSystemEvent(logTypes.downloadServiceDelta, { service, image })
						requestTimeout = opts.deltaRequestTimeout # checkInt(conf['RESIN_SUPERVISOR_DELTA_REQUEST_TIMEOUT'], positive: true) ? 30 * 60 * 1000
						totalTimeout = opts.deltaTotalTimeout # checkInt(conf['RESIN_SUPERVISOR_DELTA_TOTAL_TIMEOUT'], positive: true) ? 24 * 60 * 60 * 1000
						{ uuid, apiKey, apiEndpoint, deltaEndpoint } = opts
						@docker.rsyncImageWithProgress(image, { requestTimeout, totalTimeout, uuid, apiKey, apiEndpoint, deltaEndpoint }, onProgress)
					else
						@logger.logSystemEvent(logTypes.downloadService, { service, image })
						{ uuid, apiKey } = opts
						@docker.fetchImageWithProgress(image, onProgress, { uuid, apiKey })
				.then =>
					@logger.logSystemEvent(logTypes.downloadServiceSuccess, { service, image })

					@reportServiceStatus(service.serviceId, { status: 'Idle', download_progress: null }) if service.serviceId?
					@docker.getImage(image).inspect()
				.catch (err) =>
					@logger.logSystemEvent(logTypes.downloadServiceError, { service, image, error: err })
					throw err

	markAsSupervised: (image) =>
		@db.upsertModel(@modelName, { image }, { image })

	remove: (imageName, service = {}) =>
		@docker.normaliseImageName(imageName)
		.then (image) =>
			@logger.logSystemEvent(logTypes.deleteImageForService, { service, image })
			@docker.getImage(image).remove(force: true)
			.then =>
				@db.models(@modelName).del().where({ image })
				@logger.logSystemEvent(logTypes.deleteImageForServiceSuccess, { service, image })
			.catch ImageNotFoundError, (err) =>
				@logger.logSystemEvent(logTypes.imageAlreadyDeleted, { service, image })
			.catch (err) =>
				@logger.logSystemEvent(logTypes.deleteImageForServiceError, { service, image, error: err })
				throw err

	# Used when normalising after an update, marks all current docker images except the supervisor as supervised
	superviseAll: =>
		@docker.normaliseImageName(constants.supervisorImage)
		.then (normalisedSupervisorTag) =>
			@docker.listImages()
			.map (image) =>
				image.NormalisedRepoTags = Promise.map(image.RepoTags, (tag) => @docker.normaliseImageName(tag))
				Promise.props(image)
			.map (image) =>
				if !_.includes(image.NormalisedRepoTags, normalisedSupervisorTag)
					Promise.map image.NormalisedRepoTags, (tag) =>
						@markAsSupervised(tag)

	getAll: =>
		Promise.join(
			@docker.listImages()
			.map (image) =>
				image.NormalisedRepoTags = Promise.map(image.RepoTags, (tag) => @docker.normaliseImageName(tag))
				Promise.props(image)
			@db.models(@modelName).select()
			(images, supervisedImages) ->
				return _.filter images, (image) ->
					_.some image.NormalisedRepoTags, (tag) ->
						_.includes(supervisedImages, tag)
		)

	get: (image) =>
		@docker.getImage(image).inspect()

	cleanup: (protectedImages) =>
		Promise.join(
			@getAll()
			Promise.map(protectedImages, (image) => @docker.normaliseImageName(image))
			(images, normalisedProtectedImages) ->
				return _.reject images, (image) ->
					_.some image.NormalisedRepoTags, (tag) ->
						_.includes(normalisedProtectedImages, tag)
		)
		.then (imagesToClean) =>
			Promise.map imagesToClean, (image) =>
				Promise.map image.RepoTags.concat(image.Id), (tag) =>
					@getImage(tag).remove()
					.then =>
						@db.models(@modelName).del().where({ image: tag })
					.then ->
						console.log('Deleted image:', tag, image.Id, image.RepoTags)
					.catch(_.noop)
