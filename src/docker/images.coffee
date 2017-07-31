Promise = require 'bluebird'
_ = require 'lodash'
logTypes = require '../lib/log-types'
constants = require '../lib/constants'

ImageNotFoundError = (err) ->
	return "#{err.statusCode}" is '404'

module.exports = class Images
	constructor: ({ @docker, @logger, @db }) ->

	fetch: (imageName, opts) =>
		onProgress = (progress) ->
			opts.progressReportFn?({ download_progress: progress.percentage })
		@get(imageName)
		.catch (error) =>
			@normalise(imageName)
			.then (image) =>
				opts.progressReportFn?({ status: 'Downloading', download_progress: 0 })
				@markAsSupervised(image)
				.then =>
					if opts.delta
						@logger.logSystemEvent(logTypes.downloadImageDelta, { image })
						requestTimeout = opts.deltaRequestTimeout # checkInt(conf['RESIN_SUPERVISOR_DELTA_REQUEST_TIMEOUT'], positive: true) ? 30 * 60 * 1000
						totalTimeout = opts.deltaTotalTimeout # checkInt(conf['RESIN_SUPERVISOR_DELTA_TOTAL_TIMEOUT'], positive: true) ? 24 * 60 * 60 * 1000
						{ uuid, apiKey, apiEndpoint, deltaEndpoint } = opts
						@docker.rsyncImageWithProgress(image, { requestTimeout, totalTimeout, uuid, apiKey, apiEndpoint, deltaEndpoint }, onProgress)
					else
						@logger.logSystemEvent(logTypes.downloadImage, { image })
						{ uuid, apiKey } = opts
						@docker.fetchImageWithProgress(image, onProgress, { uuid, apiKey })
				.then =>
					@logger.logSystemEvent(logTypes.downloadImageSuccess, { image })
					opts.progressReportFn?({ status: 'Idle', download_progress: null })
					@docker.getImage(image).inspect()
				.catch (err) =>
					@logger.logSystemEvent(logTypes.downloadImageError, { image, error: err })
					throw err

	markAsSupervised: (image) =>
		@db.upsertModel('image', { image }, { image })

	remove: (imageName) =>
		@normalise(imageName)
		.then (image) =>
			@logger.logSystemEvent(logTypes.deleteImage, { image })
			@docker.getImage(image).remove(force: true)
			.then =>
				@db.models('image').del().where({ image })
				@logger.logSystemEvent(logTypes.deleteImageSuccess, { image })
			.catch ImageNotFoundError, (err) =>
				@logger.logSystemEvent(logTypes.imageAlreadyDeleted, { image })
			.catch (err) =>
				@logger.logSystemEvent(logTypes.deleteImageError, { image, error: err })
				throw err

	# Used when normalising after an update, marks all current docker images except the supervisor as supervised
	superviseAll: =>
		@normalise(constants.supervisorImage)
		.then (normalisedSupervisorTag) =>
			@docker.listImages()
			.map (image) =>
				image.NormalisedRepoTags = Promise.map(image.RepoTags, (tag) => @normalise(tag))
				Promise.props(image)
			.map (image) =>
				if !_.includes(image.NormalisedRepoTags, normalisedSupervisorTag)
					Promise.map image.NormalisedRepoTags, (tag) =>
						@markAsSupervised(tag)

	getAll: =>
		Promise.join(
			@docker.listImages()
			.map (image) =>
				image.NormalisedRepoTags = Promise.map(image.RepoTags, (tag) => @normalise(tag))
				Promise.props(image)
			@db.models('image').select()
			(images, supervisedImages) ->
				return _.filter images, (image) ->
					_.some image.NormalisedRepoTags, (tag) ->
						_.includes(supervisedImages, tag)
		)

	getImagesToCleanup: =>
		images = []
		@docker.getRegistryAndName(constants.supervisorImage)
		.then (supervisorImageInfo) =>
			@docker.listImages()
			.map (image) =>
				Promise.map image.RepoTags, (repoTag) =>
					@docker.getRegistryAndName(repoTag)
					.then ({ imageName, tagName }) ->
						if imageName == supervisorImageInfo.imageName and tagName != supervisorImageInfo.tagName
							images.push(repoTag)
		.then =>
			@docker.listImages(filters: { dangling: [ 'true' ] })
			.map (image) ->
				images.push(image.Id)
		.then ->
			return images

	get: (image) =>
		@docker.getImage(image).inspect()

	normalise: (image) =>
		@docker.normaliseImageName(image)

	cleanupOld: (protectedImages) =>
		Promise.join(
			@getAll()
			Promise.map(protectedImages, (image) => @normalise(image))
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
						@db.models('image').del().where({ image: tag })
					.then ->
						console.log('Deleted image:', tag, image.Id, image.RepoTags)
					.catch(_.noop)

	# Delete old supervisor images and dangling images
	# TODO: handle errors better, otherwise it will fail continuously
	cleanup: =>
		@getImagesToCleanup()
		.map (image) =>
			@docker.getImage(image).remove(force: true)
			.catch (err) =>
				@logger.logSystemMessage("Error during image cleanup: #{err.message}", { error: err }, 'Image cleanup error')
