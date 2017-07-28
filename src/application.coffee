_ = require 'lodash'
url = require 'url'
Lock = require 'rwlock'
knex = require './db'
config = require './config'
dockerUtils = require './docker-utils'
Promise = require 'bluebird'
utils = require './utils'
logger = require './lib/logger'
{ cachedResinApi, request } = require './request'
device = require './device'
lockFile = Promise.promisifyAll(require('lockfile'))
bootstrap = require './bootstrap'
TypedError = require 'typed-error'
fs = Promise.promisifyAll(require('fs'))
JSONStream = require 'JSONStream'
proxyvisor = require './proxyvisor'
{ checkInt, checkTruthy } = require './lib/validation'
osRelease = require './lib/os-release'
deviceConfig = require './device-config'
network = require './network'
containerConfig = require './lib/container-config'

class UpdatesLockedError extends TypedError
ImageNotFoundError = (err) ->
	return "#{err.statusCode}" is '404'

{ docker } = dockerUtils

application = {}
application.UpdatesLockedError = UpdatesLockedError
application.localMode = false



application.kill = kill = (app, { updateDB = true, removeContainer = true } = {}) ->
	logSystemEvent(logTypes.stopApp, app)
	device.updateState(status: 'Stopping')
	container = docker.getContainer(app.containerId)
	container.stop(t: 10)
	.then ->
		container.remove(v: true) if removeContainer
		return
	# Bluebird throws OperationalError for errors resulting in the normal execution of a promisified function.
	.catch Promise.OperationalError, (err) ->
		# Get the statusCode from the original cause and make sure statusCode its definitely a string for comparison
		# reasons.
		statusCode = '' + err.statusCode
		# 304 means the container was already stopped - so we can just remove it
		if statusCode is '304'
			logSystemEvent(logTypes.stopAppNoop, app)
			container.remove(v: true) if removeContainer
			return
		# 404 means the container doesn't exist, precisely what we want! :D
		if statusCode is '404'
			logSystemEvent(logTypes.stopRemoveAppNoop, app)
			return
		throw err
	.tap ->
		lockFile.unlockAsync(tmpLockPath(app))
	.tap ->
		device.isResinOSv1()
		.then (isV1) ->
			lockFile.unlockAsync(persistentLockPath(app)) if isV1
	.tap ->
		logSystemEvent(logTypes.stopAppSuccess, app)
		if removeContainer && updateDB
			app.containerId = null
			knex('app').update(app).where(appId: app.appId)
	.catch (err) ->
		logSystemEvent(logTypes.stopAppError, app, err)
		throw err

application.deleteImage = deleteImage = (app) ->
	logSystemEvent(logTypes.deleteImageForApp, app)
	docker.getImage(app.imageId).remove(force: true)
	.then ->
		logSystemEvent(logTypes.deleteImageForAppSuccess, app)
	.catch ImageNotFoundError, (err) ->
		logSystemEvent(logTypes.imageAlreadyDeleted, app)
	.catch (err) ->
		logSystemEvent(logTypes.deleteImageForAppError, app, err)
		throw err

isValidPort = (port) ->
	maybePort = parseInt(port, 10)
	return parseFloat(port) is maybePort and maybePort > 0 and maybePort < 65535

fetch = (app, setDeviceUpdateState = true) ->
	onProgress = (progress) ->
		device.updateState(download_progress: progress.percentage)

	docker.getImage(app.imageId).inspect()
	.catch (error) ->
		device.updateState(status: 'Downloading', download_progress: 0)

		Promise.try ->
			conf = JSON.parse(app.config)
			config.getArray([ 'currentApiKey', 'uuid', 'apiEndpoint', 'deltaEndpoint' ])
			.spread (apiKey, uuid, apiEndpoint, deltaEndpoint) ->
				if conf['RESIN_SUPERVISOR_DELTA'] == '1'
					logSystemEvent(logTypes.downloadAppDelta, app)
					requestTimeout = checkInt(conf['RESIN_SUPERVISOR_DELTA_REQUEST_TIMEOUT'], positive: true) ? 30 * 60 * 1000
					totalTimeout = checkInt(conf['RESIN_SUPERVISOR_DELTA_TOTAL_TIMEOUT'], positive: true) ? 24 * 60 * 60 * 1000
					dockerUtils.rsyncImageWithProgress(app.imageId, { requestTimeout, totalTimeout, uuid, apiKey, apiEndpoint, deltaEndpoint }, onProgress)
				else
					logSystemEvent(logTypes.downloadApp, app)
					dockerUtils.fetchImageWithProgress(app.imageId, onProgress, { uuid, apiKey })
		.then ->
			logSystemEvent(logTypes.downloadAppSuccess, app)
			device.updateState(status: 'Idle', download_progress: null)
			device.setUpdateState(update_downloaded: true) if setDeviceUpdateState
			docker.getImage(app.imageId).inspect()
		.catch (err) ->
			logSystemEvent(logTypes.downloadAppError, app, err)
			throw err

shouldMountKmod = (image) ->
	device.isResinOSv1().then (isV1) ->
		return false if not isV1
		Promise.using docker.imageRootDirMounted(image), (rootDir) ->
			osRelease.getOSVersion(rootDir + '/etc/os-release')
		.then (version) ->
			return version? and /^(Debian|Raspbian)/i.test(version)
		.catch (err) ->
			console.error('Error getting app OS release: ', err)
			return false

isExecFormatError = (err) ->
	message = ''
	try
		message = err.json.trim()
	/exec format error$/.test(message)

application.start = start = (app) ->
	device.isResinOSv1().then (isV1) ->
		volumes = containerConfig.defaultVolumes(isV1)
		binds = containerConfig.defaultBinds(app.appId, isV1)
		alreadyStarted = false
		Promise.try ->
			# Parse the env vars before trying to access them, that's because they have to be stringified for knex..
			return [ JSON.parse(app.env), JSON.parse(app.config) ]
		.spread (env, conf) ->
			if env.PORT?
				portList = env.PORT
				.split(',')
				.map((port) -> port.trim())
				.filter(isValidPort)

			if app.containerId?
				# If we have a container id then check it exists and if so use it.
				container = docker.getContainer(app.containerId)
				containerPromise = container.inspect().return(container)
			else
				containerPromise = Promise.rejected()

			# If there is no existing container then create one instead.
			containerPromise.catch ->
				fetch(app)
				.then (imageInfo) ->
					logSystemEvent(logTypes.installApp, app)
					device.updateState(status: 'Installing')

					ports = {}
					portBindings = {}
					if portList?
						portList.forEach (port) ->
							ports[port + '/tcp'] = {}
							portBindings[port + '/tcp'] = [ HostPort: port ]

					if imageInfo?.Config?.Cmd
						cmd = imageInfo.Config.Cmd
					else
						cmd = [ '/bin/bash', '-c', '/start' ]

					restartPolicy = createRestartPolicy({ name: conf['RESIN_APP_RESTART_POLICY'], maximumRetryCount: conf['RESIN_APP_RESTART_RETRIES'] })
					shouldMountKmod(app.imageId)
					.then (shouldMount) ->
						binds.push('/bin/kmod:/bin/kmod:ro') if shouldMount
						docker.createContainer(
							Image: app.imageId
							Cmd: cmd
							Tty: true
							Volumes: volumes
							Env: _.map env, (v, k) -> k + '=' + v
							ExposedPorts: ports
							HostConfig:
								Privileged: true
								NetworkMode: 'host'
								PortBindings: portBindings
								Binds: binds
								RestartPolicy: restartPolicy
						)
					.tap ->
						logSystemEvent(logTypes.installAppSuccess, app)
					.catch (err) ->
						logSystemEvent(logTypes.installAppError, app, err)
						throw err
			.tap (container) ->
				logSystemEvent(logTypes.startApp, app)
				device.updateState(status: 'Starting')
				container.start()
				.catch (err) ->
					statusCode = '' + err.statusCode
					# 304 means the container was already started, precisely what we want :)
					if statusCode is '304'
						alreadyStarted = true
						return

					if statusCode is '500' and isExecFormatError(err)
						# Provide a friendlier error message for "exec format error"
						device.getDeviceType()
						.then (deviceType) ->
							throw  new Error("Application architecture incompatible with #{deviceType}: exec format error")
					else
						# rethrow the same error
						throw err
				.catch (err) ->
					# If starting the container failed, we remove it so that it doesn't litter
					container.remove(v: true)
					.then ->
						app.containerId = null
						knex('app').update(app).where(appId: app.appId)
					.finally ->
						logSystemEvent(logTypes.startAppError, app, err)
						throw err
				.then ->
					app.containerId = container.id
					device.updateState(commit: app.commit)
					logger.attach(app)
			.tap (container) ->
				# Update the app info, only if starting the container worked.
				knex('app').update(app).where(appId: app.appId)
				.then (affectedRows) ->
					knex('app').insert(app) if affectedRows == 0
		.tap ->
			if alreadyStarted
				logSystemEvent(logTypes.startAppNoop, app)
			else
				logSystemEvent(logTypes.startAppSuccess, app)
		.finally ->
			device.updateState(status: 'Idle')

validRestartPolicies = [ 'no', 'always', 'on-failure', 'unless-stopped' ]
# Construct a restart policy based on its name and maximumRetryCount.
# Both arguments are optional, and the default policy is "always".
#
# Throws exception if an invalid policy name is given.
# Returns a RestartPolicy { Name, MaximumRetryCount } object
createRestartPolicy = ({ name, maximumRetryCount }) ->
	if not name?
		name = 'always'
	if not (name in validRestartPolicies)
		throw new Error("Invalid restart policy: #{name}")
	policy = { Name: name }
	if name is 'on-failure' and maximumRetryCount?
		policy.MaximumRetryCount = maximumRetryCount
	return policy

persistentLockPath = (app) ->
	appId = app.appId ? app
	return "#{constants.rootMountPoint}#{constants.dataPath}/#{appId}/resin-updates.lock"

tmpLockPath = (app) ->
	appId = app.appId ? app
	return "#{constants.rootMountPoint}/tmp/resin-supervisor/#{appId}/resin-updates.lock"

killmePath = (app) ->
	appId = app.appId ? app
	return "#{constants.rootMountPoint}#{constants.dataPath}/#{appId}/resin-kill-me"

# At boot, all apps should be unlocked *before* start to prevent a deadlock
application.unlockAndStart = unlockAndStart = (app) ->
	lockFile.unlockAsync(persistentLockPath(app))
	.then ->
		start(app)

ENOENT = (err) -> err.code is 'ENOENT'

application.lockUpdates = lockUpdates = do ->
	_lock = new Lock()
	_writeLock = Promise.promisify(_lock.async.writeLock)
	return (app, force) ->
		device.isResinOSv1()
		.then (isV1) ->
			persistentLockName = persistentLockPath(app)
			tmpLockName = tmpLockPath(app)
			_writeLock(tmpLockName)
			.tap (release) ->
				if isV1 and force != true
					lockFile.lockAsync(persistentLockName)
					.catch ENOENT, _.noop
					.catch (err) ->
						release()
						throw new UpdatesLockedError("Updates are locked: #{err.message}")
			.tap (release) ->
				if force != true
					lockFile.lockAsync(tmpLockName)
					.catch ENOENT, _.noop
					.catch (err) ->
						Promise.try ->
							lockFile.unlockAsync(persistentLockName) if isV1
						.finally ->
							release()
							throw new UpdatesLockedError("Updates are locked: #{err.message}")
			.disposer (release) ->
				Promise.try ->
					lockFile.unlockAsync(tmpLockName) if force != true
				.then ->
					lockFile.unlockAsync(persistentLockName) if isV1 and force != true
				.finally ->
					release()

joinErrorMessages = (failures) ->
	s = if failures.length > 1 then 's' else ''
	messages = _.map failures, (err) ->
		err.message or err
	"#{failures.length} error#{s}: #{messages.join(' - ')}"

# Function to start the application update polling
application.poll = ->
	config.get('appUpdatePollInterval')
	.then (interval) ->
		updateStatus.intervalHandle = setInterval(->
			application.update()
		, interval)

# Callback function to set the API poll interval dynamically.
apiPollInterval = (val) ->
	interval = checkInt(val, positive: true) ? 60000
	console.log('New API poll interval: ' + val)
	clearInterval(updateStatus.intervalHandle)
	config.set('appUpdatePollInterval', interval)
	.then ->
		application.poll()

setLocalMode = (val) ->
	mode = checkTruthy(val) ? false
	device.getOSVariant()
	.then (variant) ->
		if variant is not 'dev'
			logSystemMessage('Not a development OS, ignoring local mode', {}, 'Ignore local mode')
			return
		Promise.try ->
			if mode and !application.localMode
				logSystemMessage('Entering local mode, app will be forcefully stopped', {}, 'Enter local mode')
				Promise.map utils.getKnexApps(), (theApp) ->
					Promise.using application.lockUpdates(theApp.appId, true), ->
						# There's a slight chance the app changed after the previous select
						# So we fetch it again now the lock is acquired
						utils.getKnexApp(theApp.appId)
						.then (app) ->
							application.kill(app) if app?
			else if !mode and application.localMode
				logSystemMessage('Exiting local mode, app will be resumed', {}, 'Exit local mode')
				Promise.map utils.getKnexApps(), (app) ->
					unlockAndStart(app)
		.then ->
			application.localMode = mode

specialActionConfigVars = [
	[ 'RESIN_SUPERVISOR_LOCAL_MODE', setLocalMode ]
	[ 'RESIN_SUPERVISOR_VPN_CONTROL', utils.vpnControl ]
	[ 'RESIN_SUPERVISOR_CONNECTIVITY_CHECK', network.enableConnectivityCheck ]
	[ 'RESIN_SUPERVISOR_POLL_INTERVAL', apiPollInterval ]
	[ 'RESIN_SUPERVISOR_LOG_CONTROL', utils.resinLogControl ]
]

executedSpecialActionConfigVars = {}

executeSpecialActionsAndHostConfig = (conf, oldConf) ->
	Promise.mapSeries specialActionConfigVars, ([ key, specialActionCallback ]) ->
		if (conf[key]? or oldConf[key]?) and specialActionCallback?
			# This makes the Special Action Envs only trigger their functions once.
			if executedSpecialActionConfigVars[key] != conf[key]
				logSpecialAction(key, conf[key])
				Promise.try ->
					specialActionCallback(conf[key])
				.then ->
					executedSpecialActionConfigVars[key] = conf[key]
					logSpecialAction(key, conf[key], true)
	.then ->
		hostConfigVars = _.pickBy conf, (val, key) ->
			return _.startsWith(key, device.hostConfigConfigVarPrefix)
		oldHostConfigVars = _.pickBy oldConf, (val, key) ->
			return _.startsWith(key, device.hostConfigConfigVarPrefix)
		if !_.isEqual(hostConfigVars, oldHostConfigVars)
			device.setHostConfig(hostConfigVars, oldHostConfigVars, logSystemMessage)

getAndApplyDeviceConfig = ->
	deviceConfig.get()
	.then ({ values, targetValues }) ->
		executeSpecialActionsAndHostConfig(targetValues, values)
		.tap ->
			deviceConfig.set({ values: targetValues }) if !_.isEqual(values, targetValues)
		.then (needsReboot) ->
			if needsReboot
				logSystemMessage('Rebooting', {}, 'Reboot')
				Promise.delay(1000)
				.then ->
					device.reboot()

wrapAsError = (err) ->
	return err if _.isError(err)
	return new Error(err.message ? err)

# Wait for app to signal it's ready to die, or timeout to complete.
# timeout defaults to 1 minute.
waitToKill = (app, timeout) ->
	startTime = Date.now()
	pollInterval = 100
	timeout = checkInt(timeout, positive: true) ? 60000
	checkFileOrTimeout = ->
		fs.statAsync(killmePath(app))
		.catch (err) ->
			throw err unless (Date.now() - startTime) > timeout
		.then ->
			fs.unlinkAsync(killmePath(app)).catch(_.noop)
	retryCheck = ->
		checkFileOrTimeout()
		.catch ->
			Promise.delay(pollInterval).then(retryCheck)
	retryCheck()

UPDATE_IDLE = 0
UPDATE_UPDATING = 1
UPDATE_REQUIRED = 2
UPDATE_SCHEDULED = 3

updateStatus =
	state: UPDATE_IDLE
	failed: 0
	forceNext: false
	intervalHandle: null

updateStrategies =
	'download-then-kill': ({ localApp, app, needsDownload, force }) ->
		Promise.try ->
			fetch(app) if needsDownload
		.then ->
			Promise.using lockUpdates(localApp, force), ->
				logSystemEvent(logTypes.updateApp, app) if localApp.imageId == app.imageId
				utils.getKnexApp(localApp.appId)
				.then(kill)
				.then ->
					start(app)
			.catch (err) ->
				logSystemEvent(logTypes.updateAppError, app, err) unless err instanceof UpdatesLockedError
				throw err
	'kill-then-download': ({ localApp, app, needsDownload, force }) ->
		Promise.using lockUpdates(localApp, force), ->
			logSystemEvent(logTypes.updateApp, app) if localApp.imageId == app.imageId
			utils.getKnexApp(localApp.appId)
			.then(kill)
			.then ->
				fetch(app) if needsDownload
			.then ->
				start(app)
		.catch (err) ->
			logSystemEvent(logTypes.updateAppError, app, err) unless err instanceof UpdatesLockedError
			throw err
	'delete-then-download': ({ localApp, app, needsDownload, force }) ->
		Promise.using lockUpdates(localApp, force), ->
			logSystemEvent(logTypes.updateApp, app) if localApp.imageId == app.imageId
			utils.getKnexApp(localApp.appId)
			.tap(kill)
			.then (appFromDB) ->
				# If we don't need to download a new image,
				# there's no use in deleting the image
				if needsDownload
					deleteImage(appFromDB)
					.then ->
						fetch(app)
			.then ->
				start(app)
		.catch (err) ->
			logSystemEvent(logTypes.updateAppError, app, err) unless err instanceof UpdatesLockedError
			throw err
	'hand-over': ({ localApp, app, needsDownload, force, timeout }) ->
		Promise.using lockUpdates(localApp, force), ->
			utils.getKnexApp(localApp.appId)
			.then (localApp) ->
				Promise.try ->
					fetch(app) if needsDownload
				.then ->
					logSystemEvent(logTypes.updateApp, app) if localApp.imageId == app.imageId
					start(app)
				.then ->
					waitToKill(localApp, timeout)
				.then ->
					kill(localApp, updateDB: false)
		.catch (err) ->
			logSystemEvent(logTypes.updateAppError, app, err) unless err instanceof UpdatesLockedError
			throw err


updateUsingStrategy = (strategy, options) ->
	if not _.has(updateStrategies, strategy)
		strategy = 'download-then-kill'
	updateStrategies[strategy](options)

getRemoteState = (uuid, apiKey) ->
	endpoint = url.resolve(config.apiEndpoint, "/device/v1/#{uuid}/state")

	requestParams = _.extend
		method: 'GET'
		url: "#{endpoint}?&apikey=#{apiKey}"
	, cachedResinApi.passthrough

	cachedResinApi._request(requestParams)
	.timeout(config.apiTimeout)
	.catch (err) ->
		console.error("Failed to get state for device #{uuid}. #{err}")
		throw err

# TODO: Actually store and use app.environment and app.config separately
parseEnvAndFormatRemoteApps = (remoteApps, uuid, apiKey) ->
	Promise.join(
		config.getMany(['listenPort', 'name', 'apiSecret', 'version', 'deviceType'])
		device.getOSVersion()
		([ listenPort, name, apiSecret, version, deviceType ], osVersion) ->
			appsWithEnv = _.mapValues remoteApps, (app, appId) ->
				extendEnvVarsOpts = {
					uuid
					appId
					appName: app.name
					commit: app.commit
					listenPort
					name
					apiSecret
					deviceApiKey: apiKey
					version
					osVersion
					deviceType
				}
				containerConfig.extendEnvVars(app.environment, extendEnvVarsOpts)
				.then (env) ->
					app.config ?= {}
					return {
						appId
						commit: app.commit
						imageId: app.image
						env: JSON.stringify(env)
						config: JSON.stringify(app.config)
						name: app.name
					}
			Promise.props(appsWithEnv)
	)

formatLocalApps = (apps) ->
	apps = _.keyBy(apps, 'appId')
	localApps = _.mapValues apps, (app) ->
		app = _.pick(app, [ 'appId', 'commit', 'imageId', 'env', 'config', 'name' ])
	return localApps

restartVars = (conf) ->
	return _.pick(conf, [ 'RESIN_DEVICE_RESTART', 'RESIN_RESTART' ])

compareForUpdate = (localApps, remoteApps) ->
	remoteAppIds = _.keys(remoteApps)
	localAppIds = _.keys(localApps)

	toBeRemoved = _.difference(localAppIds, remoteAppIds)
	toBeInstalled = _.difference(remoteAppIds, localAppIds)

	matchedAppIds = _.intersection(remoteAppIds, localAppIds)
	toBeUpdated = _.filter matchedAppIds, (appId) ->
		localApp = _.omit(localApps[appId], 'config')
		remoteApp = _.omit(remoteApps[appId], 'config')
		localApp.env = _.omit(JSON.parse(localApp.env), 'RESIN_DEVICE_NAME_AT_INIT')
		remoteApp.env = _.omit(JSON.parse(remoteApp.env), 'RESIN_DEVICE_NAME_AT_INIT')
		return !_.isEqual(remoteApp, localApp) or
			!_.isEqual(restartVars(JSON.parse(localApps[appId].config)), restartVars(JSON.parse(remoteApps[appId].config)))

	appsWithUpdatedConfigs = _.filter matchedAppIds, (appId) ->
		return !_.includes(toBeUpdated, appId) and
			!_.isEqual(localApps[appId].config, remoteApps[appId].config)

	toBeDownloaded = _.filter toBeUpdated, (appId) ->
		return !_.isEqual(remoteApps[appId].imageId, localApps[appId].imageId)
	toBeDownloaded = _.union(toBeDownloaded, toBeInstalled)
	allAppIds = _.union(localAppIds, remoteAppIds)
	return { toBeRemoved, toBeDownloaded, toBeInstalled, toBeUpdated, appsWithUpdatedConfigs, remoteAppIds, allAppIds }

application.update = do ->
	_updateRunning = false
	return Promise.method (targetState, { force }) ->
		throw new Error('An update is already running') if _updateRunning # ApiBinder should ensure this doesn't happen
		_updateRunning = true
		device.getCurrentState()
		.then ({ localCurrent, dependentCurrent }) ->
			{ localTarget, dependentTarget } = targetState


application.update = update = (force, scheduled = false) ->
	switch updateStatus.state
		when UPDATE_SCHEDULED
			if scheduled isnt true
				# There's an update scheduled but it isn't this one, so just stop
				# but if we have to force an update, do it in the one that is scheduled
				updateStatus.forceNext or= force
				return
		when UPDATE_IDLE
			# All good, carry on with the update.
		else
			# Mark an update required after the current in-progress update.
			updateStatus.forceNext or= force
			updateStatus.state = UPDATE_REQUIRED
			return

	force or= updateStatus.forceNext
	updateStatus.forceNext = false
	updateStatus.state = UPDATE_UPDATING
	bootstrap.done.then ->
		Promise.join utils.getConfig('apiKey'), utils.getConfig('uuid'), utils.getConfig('name'), knex('app').select(), (apiKey, uuid, deviceName, apps) ->
			getRemoteState(uuid, apiKey)
			.then ({ local, dependent }) ->
				proxyvisor.fetchAndSetTargetsForDependentApps(dependent, fetch, apiKey)
				.then ->
					config.set('name', local.name) if local.name != deviceName
				.then ->
					parseEnvAndFormatRemoteApps(local.apps, uuid, apiKey)
			.tap (remoteApps) ->
				# Before running the updates, try to clean up any images that aren't in use
				# and will not be used in the target state
				return if application.localMode or device.shuttingDown
				dockerUtils.cleanupContainersAndImages(_.map(remoteApps, 'imageId'))
				.catch (err) ->
					console.log('Cleanup failed: ', err, err.stack)
			.then (remoteApps) ->
				localApps = formatLocalApps(apps)
				resourcesForUpdate = compareForUpdate(localApps, remoteApps)
				{ toBeRemoved, toBeDownloaded, toBeInstalled, toBeUpdated, appsWithUpdatedConfigs, remoteAppIds, allAppIds } = resourcesForUpdate

				if !_.isEmpty(toBeRemoved) or !_.isEmpty(toBeInstalled) or !_.isEmpty(toBeUpdated)
					device.setUpdateState(update_pending: true)
				# Run special functions against variables
				Promise.try ->
					remoteDeviceConfig = {}
					_.map remoteAppIds, (appId) ->
						_.merge(remoteDeviceConfig, JSON.parse(remoteApps[appId].config))
					deviceConfig.get()
					.then ({ values, targetValues }) ->
						# If the new device config is different from the target values we had, or if
						# for some reason it hasn't been applied yet (values don't match target), we apply it.
						if !_.isEqual(targetValues, remoteDeviceConfig) or !_.isEqual(targetValues, values)
							deviceConfig.set({ targetValues: remoteDeviceConfig })
							.then ->
								getAndApplyDeviceConfig()
				.catch (err) ->
					logSystemMessage("Error fetching/applying device configuration: #{err}", { error: err }, 'Set device configuration error')
				.return(allAppIds)
				.map (appId) ->
					return if application.localMode or device.shuttingDown
					Promise.try ->
						needsDownload = _.includes(toBeDownloaded, appId)
						if _.includes(toBeRemoved, appId)
							app = localApps[appId]
							Promise.using lockUpdates(app, force), ->
								# We get the app from the DB again in case someone restarted it
								# (which would have changed its containerId)
								utils.getKnexApp(appId)
								.then(kill)
								.then ->
									knex('app').where('appId', appId).delete()
							.catch (err) ->
								logSystemEvent(logTypes.updateAppError, app, err)
								throw err
						else if _.includes(toBeInstalled, appId)
							app = remoteApps[appId]
							Promise.try ->
								fetch(app) if needsDownload
							.then ->
								start(app)
						else if _.includes(toBeUpdated, appId)
							app = remoteApps[appId]
							conf = JSON.parse(app.config)
							forceThisApp =
								conf['RESIN_SUPERVISOR_OVERRIDE_LOCK'] == '1' ||
								conf['RESIN_OVERRIDE_LOCK'] == '1'
							strategy = conf['RESIN_SUPERVISOR_UPDATE_STRATEGY']
							timeout = conf['RESIN_SUPERVISOR_HANDOVER_TIMEOUT']
							updateUsingStrategy strategy, {
								localApp: localApps[appId]
								app
								needsDownload
								force: force || forceThisApp
								timeout
							}
						else if _.includes(appsWithUpdatedConfigs, appId)
							# These apps have no changes other than config variables.
							# It can notoriously affect setting dep. devices hook address
							# if nothing else changes in the app.
							# So we just save them.
							app = remoteApps[appId]
							logSystemEvent(logTypes.updateAppConfig, app)
							knex('app').update(app).where({ appId })
							.then ->
								logSystemEvent(logTypes.updateAppConfigSuccess, app)
							.catch (err) ->
								logSystemEvent(logTypes.updateAppConfigError, app, err)
								throw err
					.catch(wrapAsError)
		.filter(_.isError)
		.then (failures) ->
			_.each(failures, (err) -> console.error('Error:', err, err.stack))
			throw new Error(joinErrorMessages(failures)) if failures.length > 0
		.then ->
			proxyvisor.sendUpdates() if !device.shuttingDown
		.then ->
			return if application.localMode or device.shuttingDown
			updateStatus.failed = 0
			device.setUpdateState(update_pending: false, update_downloaded: false, update_failed: false)
			# We cleanup here as we want a point when we have a consistent apps/images state, rather than potentially at a
			# point where we might clean up an image we still want.
			dockerUtils.cleanupContainersAndImages()
		.catch (err) ->
			updateStatus.failed++
			device.setUpdateState(update_failed: true)
			if updateStatus.state in [ UPDATE_REQUIRED, UPDATE_SCHEDULED ]
				console.log('Updating failed, but there is already another update scheduled immediately: ', err)
				return
			delayTime = Math.min((2 ** updateStatus.failed) * 500, 30000)
			# If there was an error then schedule another attempt briefly in the future.
			console.log('Scheduling another update attempt due to failure: ', delayTime, err)
			setTimeout(update, delayTime, force, true)
			updateStatus.state = UPDATE_SCHEDULED
		.finally ->
			switch updateStatus.state
				when UPDATE_REQUIRED
					# If an update is required then schedule it
					setTimeout(update, 1, false, true)
					updateStatus.state = UPDATE_SCHEDULED
				when UPDATE_SCHEDULED
					# Already scheduled, nothing to do here
				else
					updateStatus.state = UPDATE_IDLE
			device.updateState(status: 'Idle')
			return

listenToEvents = do ->
	appHasDied = {}
	return ->
		docker.getEvents()
		.then (stream) ->
			stream.on 'error', (err) ->
				console.error('Error on docker events stream:', err, err.stack)
			parser = JSONStream.parse()
			parser.on 'error', (err) ->
				console.error('Error on docker events JSON stream:', err, err.stack)
			parser.on 'data', (data) ->
				if data?.Type? && data.Type == 'container' && data.status in ['die', 'start']
					knex('app').select().where({ containerId: data.id })
					.then ([ app ]) ->
						if app?
							if data.status == 'die'
								logSystemEvent(logTypes.appExit, app)
								appHasDied[app.containerId] = true
							else if data.status == 'start' and appHasDied[app.containerId]
								logSystemEvent(logTypes.appRestart, app)
								logger.attach(app)
					.catch (err) ->
						console.error('Error on docker event:', err, err.stack)
			parser.on 'end', ->
				console.error('Docker events stream ended, this should never happen')
				listenToEvents()
			stream.pipe(parser)
		.catch (err) ->
			console.error('Error listening to events:', err, err.stack)

application.initialize = ->
	listenToEvents()
	getAndApplyDeviceConfig()
	.then ->
		knex('app').select()
	.map (app) ->
		unlockAndStart(app) if !application.localMode
	.catch (error) ->
		console.error('Error starting apps:', error)
	.then ->
		mixpanel.track('Start application update poll', { interval: config.appUpdatePollInterval })
		application.poll()
	.then ->
		application.update()

module.exports = (logsChannel, offlineMode) ->
	logger.init(
		pubnub: config.pubnub
		channel: "device-#{logsChannel}-logs"
		offlineMode: offlineMode
	)
	return application
