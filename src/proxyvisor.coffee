Promise = require 'bluebird'
express = require 'express'
fs = Promise.promisifyAll require 'fs'
{ resinApi, request } = require './request'

_ = require 'lodash'
deviceRegister = require 'resin-register-device'
randomHexString = require './lib/random-hex-string'
device = require './device'
bodyParser = require 'body-parser'
appConfig = require './config'

execAsync = Promise.promisify(require('child_process').exec)
url = require 'url'

isDefined = _.negate(_.isUndefined)

parseDeviceFields = (device) ->
	device.id = parseInt(device.deviceId)
	device.appId = parseInt(device.appId)
	device.config = JSON.parse(device.config ? '{}')
	device.environment = JSON.parse(device.environment ? '{}')
	device.targetConfig = JSON.parse(device.targetConfig ? '{}')
	device.targetEnvironment = JSON.parse(device.targetEnvironment ? '{}')
	return _.omit(device, 'markedForDeletion', 'logs_channel')

# TODO move to lib/validation
validStringOrUndefined = (s) ->
	_.isUndefined(s) or !_.isEmpty(s)
validObjectOrUndefined = (o) ->
	_.isUndefined(o) or _.isObject(o)

tarPath = ({ appId, commit }) ->
	return '/tmp/' + appId + '-' + commit + '.tar'

getTarArchive = (path, destination) ->
	fs.lstatAsync(path)
	.then ->
		execAsync("tar -cvf '#{destination}' *", cwd: path)

formatTargetAsState = (device) ->
	return {
		commit: device.targetCommit
		environment: device.targetEnvironment
		config: device.targetConfig
	}

class ProxyvisorRouter extends express.Router
	constructor: ({ @config, @logger, @db, @docker, @apiBinder, @reportCurrentState }) =>
		super()
		@use(bodyParser())
		@get '/v1/devices', (req, res) =>
			@db.models('dependentDevice').select()
			.map(parseDeviceFields)
			.then (devices) ->
				res.json(devices)
			.catch (err) ->
				res.status(503).send(err?.message or err or 'Unknown error')

		@post '/v1/devices', (req, res) =>
			{ appId, device_type } = req.body

			if !appId? or _.isNaN(parseInt(appId)) or parseInt(appId) <= 0
				res.status(400).send('appId must be a positive integer')
				return
			device_type = 'generic-amd64' if !device_type?
			d =
				application: req.body.appId
				device_type: device_type
			@apiBinder.provisionDependentDevice(d)
			.then (dev) =>
				# If the response has id: null then something was wrong in the request
				# but we don't know precisely what.
				if !dev.id?
					res.status(400).send('Provisioning failed, invalid appId or credentials')
					return
				deviceForDB = {
					uuid: dev.uuid
					appId: dev.application
					device_type: dev.device_type
					deviceId: dev.id
					name: dev.name
					status: dev.status
					logs_channel: dev.logs_channel
				}
				@db.models('dependentDevice').insert(deviceForDB)
				.then ->
					res.status(201).send(dev)
			.catch (err) ->
				console.error("Error on #{req.method} #{url.parse(req.url).pathname}", err, err.stack)
				res.status(503).send(err?.message or err or 'Unknown error')

		@get '/v1/devices/:uuid', (req, res) =>
			uuid = req.params.uuid
			@db.models('dependentDevice').select().where({ uuid })
			.then ([ device ]) ->
				return res.status(404).send('Device not found') if !device?
				return res.status(410).send('Device deleted') if device.markedForDeletion
				res.json(parseDeviceFields(device))
			.catch (err) ->
				console.error("Error on #{req.method} #{url.parse(req.url).pathname}", err, err.stack)
				res.status(503).send(err?.message or err or 'Unknown error')

		@post '/v1/devices/:uuid/logs', (req, res) =>
			uuid = req.params.uuid
			m = {
				message: req.body.message
				timestamp: req.body.timestamp or Date.now()
			}
			m.isSystem = req.body.isSystem if req.body.isSystem?

			@db.models('dependentDevice').select().where({ uuid })
			.then ([ device ]) =>
				return res.status(404).send('Device not found') if !device?
				return res.status(410).send('Device deleted') if device.markedForDeletion
				@logger.log(m, { channel: "device-#{device.logs_channel}-logs" })
				res.status(202).send('OK')
			.catch (err) ->
				console.error("Error on #{req.method} #{url.parse(req.url).pathname}", err, err.stack)
				res.status(503).send(err?.message or err or 'Unknown error')

		@put '/v1/devices/:uuid', (req, res) =>
			uuid = req.params.uuid
			{ status, is_online, commit, buildId, environment, config } = req.body
			if isDefined(is_online) and !_.isBoolean(is_online)
				res.status(400).send('is_online must be a boolean')
				return
			if !validStringOrUndefined(status)
				res.status(400).send('status must be a non-empty string')
				return
			if !validStringOrUndefined(commit)
				res.status(400).send('commit must be a non-empty string')
				return
			if !validStringOrUndefined(buildId)
				res.status(400).send('commit must be a non-empty string')
				return
			if !validObjectOrUndefined(environment)
				res.status(400).send('environment must be an object')
				return
			if !validObjectOrUndefined(config)
				res.status(400).send('config must be an object')
				return
			environment = JSON.stringify(environment) if isDefined(environment)
			config = JSON.stringify(config) if isDefined(config)

			fieldsToUpdateOnDB = _.pickBy({ status, is_online, commit, buildId, config, environment }, isDefined)
			fieldsToUpdateOnAPI = _.pick(fieldsToUpdateOnDB, 'status', 'is_online', 'commit', 'buildId')

			if _.isEmpty(fieldsToUpdateOnDB)
				res.status(400).send('At least one device attribute must be updated')
				return

			@db.models('dependentDevice').select().where({ uuid })
			.then ([ device ]) =>
				return res.status(404).send('Device not found') if !device?
				return res.status(410).send('Device deleted') if device.markedForDeletion
				throw new Error('Device is invalid') if !device.deviceId?
				Promise.try =>
					if !_.isEmpty(fieldsToUpdateOnAPI)
						@apiBinder.patchDevice(device.deviceId, fieldsToUpdateOnAPI)
				.then =>
					@db.models('dependentDevice').update(fieldsToUpdateOnDB).where({ uuid })
				.then ->
					res.json(parseDeviceFields(device))
			.catch (err) ->
				console.error("Error on #{req.method} #{url.parse(req.url).pathname}", err, err.stack)
				res.status(503).send(err?.message or err or 'Unknown error')

		@get '/v1/dependent-apps/:appId/assets/:commit', (req, res) =>
			@db.models('dependentApp').select().where(_.pick(req.params, 'appId', 'commit'))
			.then ([ app ]) =>
				return res.status(404).send('Not found') if !app
				dest = tarPath(app)
				fs.lstatAsync(dest)
				.catch =>
					Promise.using @docker.imageRootDirMounted(app.image), (rootDir) ->
						getTarArchive(rootDir + '/assets', dest)
				.then ->
					res.sendFile(dest)
			.catch (err) ->
				console.error("Error on #{req.method} #{url.parse(req.url).pathname}", err, err.stack)
				res.status(503).send(err?.message or err or 'Unknown error')

		@get '/v1/dependent-apps', (req, res) =>
			@db.models('dependentApp').select()
			.map (app) ->
				return {
					id: parseInt(app.appId)
					commit: app.commit
					name: app.name
					config: JSON.parse(app.config ? '{}')
				}
			.then (apps) ->
				res.json(apps)
			.catch (err) ->
				console.error("Error on #{req.method} #{url.parse(req.url).pathname}", err, err.stack)
				res.status(503).send(err?.message or err or 'Unknown error')

module.exports = class Proxyvisor
	constructor: ({ @config, @logger, @db, @docker, @images, @reportCurrentState }) =>
		@acknowledgedState = {}
		@router = new ProxyvisorRouter({ @config, @logger, @db, @docker, @reportCurrentState })

	# TODO: deduplicate code from compareForUpdate in application.coffee
	applyTarget: (target) =>
		progressReport = (state) =>
			@reportCurrentState(state)

		@db.models('dependentApp').select()
		.then (localDependentApps) =>
			remoteApps = _.keyBy(target.apps, 'appId')
			localApps = _.keyBy(localDependentApps, 'appId')

			toBeDownloaded = _.filter remoteApps, (app, appId) ->
				return app.commit? and app.buildId? and app.image? and !_.some(localApps, image: app.image)
			toBeRemoved = _.filter localApps, (app, appId) ->
				return app.commit? and !_.some(remoteApps, image: app.image)
			toBeDeletedFromDB = _(localApps).reject((app, appId) -> remoteApps[appId]?).map('appId').value()
			Promise.map toBeDownloaded, (app) ->
				@images.fetch(app.image, app, opts, progressReport)
			.then =>
				Promise.map toBeRemoved, (app) =>
					fs.unlinkAsync(tarPath(app))
					.then =>
						@docker.getImage(app.image).remove()
					.catch (err) ->
						console.error('Could not remove image/artifacts for dependent app', err, err.stack)
			.then =>
				Promise.props(
					_.mapValues remoteApps, (app, appId) =>
						@db.models('dependentApp').update(app).where({ appId })
						.then (n) =>
							@db.models('dependentApp').insert(app) if n == 0
				)
			.then =>
				@db.models('dependentDevice').del().whereIn('appId', toBeDeletedFromDB)
			.then =>
				@db.models('dependentApp').del().whereIn('appId', toBeDeletedFromDB)
			.then =>
				@db.models('dependentDevice').update({ markedForDeletion: true }).whereNotIn('uuid', _.keys(target.devices))
			.then =>
				Promise.all _.map target.devices, (device, uuid) =>
					# Only consider one app per dependent device for now
					appId = _(device.apps).keys().head()
					targetCommit = target.apps[appId].commit
					targetEnvironment = JSON.stringify(device.apps[appId].environment ? {})
					targetConfig = JSON.stringify(device.apps[appId].config ? {})
					@db.models('dependentDevice').update({ targetEnvironment, targetConfig, targetCommit, name: device.name }).where({ uuid })
					.then (n) =>
						return if n != 0
						# If the device is not in the DB it means it was provisioned externally
						# so we need to fetch it.
						resinApi.get
							resource: 'device'
							options:
								filter:
									uuid: uuid
							customOptions:
								apikey: apiKey
						.timeout(appConfig.apiTimeout)
						.then ([ dev ]) =>
							deviceForDB = {
								uuid: uuid
								appId: appId
								device_type: dev.device_type
								deviceId: dev.id
								is_online: dev.is_online
								name: dev.name
								status: dev.status
								logs_channel: dev.logs_channel
								targetCommit
								targetConfig
								targetEnvironment
							}
							@db.models('dependentDevice').insert(deviceForDB)
		.catch (err) ->
			console.error('Error fetching dependent apps', err, err.stack)

	getHookEndpoint: (appId) =>
		@db.models('dependentApp').select('parentAppId').where({ appId })
		.then ([ { parentAppId } ]) ->
			utils.getKnexApp(parentAppId)
		.then (parentApp) =>
			conf = JSON.parse(parentApp.config)
			@docker.getImageEnv(parentApp.image)
			.then (imageEnv) ->
				return imageEnv.RESIN_DEPENDENT_DEVICES_HOOK_ADDRESS ?
					conf.RESIN_DEPENDENT_DEVICES_HOOK_ADDRESS ?
					"#{appConfig.proxyvisorHookReceiver}/v1/devices/"

	sendUpdate: (device, endpoint) =>
		stateToSend = {
			appId: parseInt(device.appId)
			commit: device.targetCommit
			environment: JSON.parse(device.targetEnvironment)
			config: JSON.parse(device.targetConfig)
		}
		request.putAsync "#{endpoint}#{device.uuid}", {
			json: true
			body: stateToSend
		}
		.timeout(appConfig.apiTimeout)
		.spread (response, body) =>
			if response.statusCode == 200
				@acknowledgedState[device.uuid] = formatTargetAsState(device)
			else
				@acknowledgedState[device.uuid] = null
				throw new Error("Hook returned #{response.statusCode}: #{body}") if response.statusCode != 202
		.catch (err) ->
			return console.error("Error updating device #{device.uuid}", err, err.stack)

	sendDeleteHook: (device, endpoint) =>
		uuid = device.uuid
		request.delAsync("#{endpoint}#{uuid}")
		.timeout(appConfig.apiTimeout)
		.spread (response, body) =>
			if response.statusCode == 200
				@db.models('dependentDevice').del().where({ uuid })
			else
				throw new Error("Hook returned #{response.statusCode}: #{body}")
		.catch (err) ->
			return console.error("Error deleting device #{device.uuid}", err, err.stack)

	sendUpdates: =>
		endpoints = {}
		@db.models('dependentDevice').select()
		.map (device) =>
			currentState = _.pick(device, 'commit', 'environment', 'config')
			targetState = formatTargetAsState(device)
			endpoints[device.appId] ?= @getHookEndpoint(device.appId)
			endpoints[device.appId]
			.then (endpoint) =>
				if device.markedForDeletion
					@sendDeleteHook(device, endpoint)
				else if device.targetCommit? and !_.isEqual(targetState, currentState) and !_.isEqual(targetState, @acknowledgedState[device.uuid])
					@sendUpdate(device, endpoint)
