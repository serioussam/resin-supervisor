Promise = require 'bluebird'
_ = require 'lodash'

logTypes = require '../lib/log-types'

module.exports = class Volumes
	constructor: ({ @docker, @logger }) ->

	format: (volume) ->
		return {
			appId: volume.Labels['io.resin.appId']
			name: volume.Name
			config: {}
		}

	getAll: =>
		@docker.listVolumes()
		.then (response) =>
			volumes = response.Volumes ? []
			Promise.map volumes, (volume) =>
				@docker.getVolume(volume.Name).inspect()
		.then (volumes) =>
			withLabel = _.filter volumes, (vol) ->
				_.includes(_.keys(vol.Labels), 'io.resin.supervised')
			return _.map withLabel, (volume) =>
				return @format(volume)

	getAllByAppId: (appId) =>
		@getAll()
		.then (volumes) ->
			_.filter(volumes, (v) -> v.appId == appId)

	get: (name) ->
		@docker.getVolume(name).inspect()
		.then (network) ->
			return @format(network)

	# TODO: what config values are relevant/whitelisted?
	create: ({ name, config, appId }) =>
		@logger.logSystemEvent(logTypes.createVolume, { volume: { name } })
		@docker.createVolume({
			Name: name
			Labels: {
				'io.resin.supervised': 'true'
				'io.resin.appId': appId
			}
		})
		.catch (err) =>
			@logger.logSystemEvent(logTypes.createVolumeError, { volume: { name }, error: err })
			throw err

	remove: ({ name }) ->
		@logger.logSystemEvent(logTypes.removeVolume, { volume: { name } })
		@docker.getVolume(name).remove()
		.catch (err) =>
			@logger.logSystemEvent(logTypes.removeVolumeError, { volume: { name }, error: err })

	isEqual: (current, target) ->
		current.config == target.config
