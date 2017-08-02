Promise = require 'bluebird'
_ = require 'lodash'

containerConfig = require './container-config'

exports.appStateToDB = (app) ->
	app.volumes ?= {}
	app.services = _.map app.services ? [], (service) ->
		service.appId = app.appId
		return service
	app.config ?= {}
	app.networks ?= {}

	dbApp = {
		appId: app.appId
		commit: app.commit
		name: app.name
		buildId: app.buildId
		config: JSON.stringify(app.config)
		services: JSON.stringify(app.services)
		networks: JSON.stringify(app.networks)
		volumes: JSON.stringify(app.volumes)
	}
	return dbApp

exports.dependentAppStateToDB = (app) ->
	app.environment ?= {}
	app.config ?= {}
	dbApp = {
		appId: app.appId
		name: app.name
		commit: app.commit
		buildId: app.buildId
		parentApp: app.parentApp
		image: app.image
		config: JSON.stringify(app.config)
		environment: JSON.stringify(app.environment)
	}
	return dbApp

defaultServiceConfig = (opts, images) ->
	return (service) ->
		serviceOpts = {
			serviceName: service.serviceName
		}
		_.assign(serviceOpts, opts)
		service.environment = containerConfig.extendEnvVars(service.environment ? {}, serviceOpts)
		service.volumes = (service.volumes ? []).concat(containerConfig.defaultBinds(service.appId, service.serviceId))
		service.labels ?= {}
		service.privileged ?= false
		service.restartPolicy = createRestartPolicy({ name: service.config['RESIN_APP_RESTART_POLICY'], maximumRetryCount: service.config['RESIN_APP_RESTART_RETRIES'] })
		service.image = images.normalise(service.image)
		service.running ?= true
		return Promise.props(service)

# Named Async cause it's the only function here that returns a Promise
exports.appDBToStateAsync = (opts, images) ->
	return (app) ->
		configOpts = {
			appName: app.name
			appId: app.appId
			commit: app.commit
			buildId: app.buildId
		}
		_.assign(configOpts, opts)
		outApp = {
			appId: app.appId
			name: app.name
			commit: app.commit
			buildId: app.buildId
			config: JSON.parse(app.config)
			services: Promise.map(JSON.parse(app.services), defaultServiceConfig(configOpts, images))
			networks: JSON.parse(app.networks)
			volumes: JSON.parse(app.volumes)
		}
		return Promise.props(outApp)

exports.dependentAppDBToState = (app) ->
	outApp = {
		appId: app.appId
		name: app.name
		commit: app.commit
		buildId: app.buildId
		image: app.image
		config: JSON.parse(app.config)
		environment: JSON.parse(app.environment)
		parentApp: app.parentApp
	}
	return outApp

exports.dependentDeviceTargetStateToDB = (device) ->
	apps = JSON.stringify(device.apps ? {})
	outDevice = {
		uuid: device.uuid
		name: device.name
		apps
	}
	return outDevice

exports.dependentDeviceTargetDBToState = (device) ->
	outDevice = {
		uuid: device.uuid
		name: device.name
		apps: JSON.parse(device.apps)
	}
	return outDevice

exports.envArrayToObject = (env) ->
	# env is an array of strings that say 'key=value'
	_(env)
	.invokeMap('split', '=')
	.fromPairs()
	.value()

validRestartPolicies = [ 'no', 'always', 'on-failure', 'unless-stopped' ]
# Construct a restart policy based on its name and maximumRetryCount.
# Both arguments are optional, and the default policy is "always".
#
# Throws exception if an invalid policy name is given.
# Returns a RestartPolicy { Name, MaximumRetryCount } object
createRestartPolicy = ({ name, maximumRetryCount }) ->
	if not name?
		name = 'unless-stopped'
	if not (name in validRestartPolicies)
		throw new Error("Invalid restart policy: #{name}")
	policy = { Name: name }
	if name is 'on-failure' and maximumRetryCount?
		policy.MaximumRetryCount = maximumRetryCount
	return policy


exports.serviceToContainerConfig = (service, { imageInfo, supervisorApiKey, resinApiKey }) ->
	if service.command?
		cmd = service.command
	else if imageInfo?.Config?.Cmd
		cmd = imageInfo.Config.Cmd

	if service.entrypoint?
		entrypoint = service.entrypoint
	else if imageInfo?.Config?.Entrypoint
		entrypoint = imageInfo.Config.Entrypoint

	ports = {}
	portBindings = {}
	if service.ports?
		_.forEach service.ports, (port) ->
			# TODO: map ports for any of the possible formats "container:host/protocol", port ranges, etc.
			ports[port + '/tcp'] = {}
			portBindings[port + '/tcp'] = [ HostPort: port ]
	if service.expose?
		_.forEach service.expose, (port) ->
			ports[port + '/tcp'] = {}

	labels = _.clone(service.labels)
	labels['io.resin.app_id'] = service.appId
	labels['io.resin.service_id'] = service.serviceId
	labels['io.resin.service_name'] = service.Name
	labels['io.resin.container_id'] = service.containerId
	labels['io.resin.build_id'] = service.buildId

	binds = []
	volumes = {}
	_.forEach service.volumes, (vol) ->
		isBind = /:/.test(vol)
		if isBind
			binds.push(vol)
		else
			volumes[vol] = {}

	if checkTruthy(labels['io.resin.features.dbus'])
		binds.push('/run/dbus:/host/run/dbus')
	if checkTruthy(labels['io.resin.features.kernel_modules'])
		binds.push('/lib/modules:/lib/modules')
	if checkTruthy(labels['io.resin.features.firmware'])
		binds.push('/lib/firmware:/lib/firmware')
	if checkTruthy(labels['io.resin.features.supervisor_api'])
		service.environment['RESIN_SUPERVISOR_API_KEY'] = supervisorApiKey
	if checkTruthy(labels['io.resin.features.resin_api'])
		service.environment['RESIN_API_KEY'] = resinApiKey

	conf = {
		Image: service.image
		Cmd: cmd
		Entrypoint: entrypoint
		Tty: true
		Volumes: volumes
		Env: _.map service.environment, (v, k) -> k + '=' + v
		ExposedPorts: ports
		HostConfig:
			Privileged: service.privileged
			NetworkMode: service.networkMode
			PortBindings: portBindings
			Binds: binds
			RestartPolicy: service.restartPolicy
	}
	console.log('Container config:', conf)
	return conf

# TODO: ports?
exports.containerToService = (container) ->
	if container.State.Running
		state = 'Idle'
	else
		state = 'Stopped'
	service = {
		appId: container.Config.Labels['io.resin.app_id']
		serviceId: container.Config.Labels['io.resin.service_id']
		serviceName: container.Config.Labels['io.resin.service_name']
		containerId: container.Config.Labels['io.resin.container_id']
		command: container.Config.Cmd
		entrypoint: container.Config.Entrypoint
		networkMode: container.HostConfig.NetworkMode
		volumes: _.concat(container.HostConfig.Binds ? [], _.keys(container.Config.Volumes ? {}))
		image: container.Config.Image
		environment: exports.envArrayToObject(container.Config.Env)
		privileged: container.HostConfig.privileged
		buildId: container.Config.Labels['io.resin.buildId']
		labels: _.omit(container.Config.Labels, [ 'io.resin.service_id', 'io.resin.service_name', 'io.resin.container_id', 'io.resin.build_id', 'io.resin.app_id' ])
		status: {
			state
			download_progress: null
		}
		running: container.State.Running
		createdAt: new Date(container.Created)
		restartPolicy: container.RestartPolicy
		dockerContainerId: container.Id
	}
	_.pull(service.volumes, containerConfig.defaultBinds(service.appId, service.serviceId))
	return service

exports.appsArrayToObject = (apps) ->
	_.keyBy(apps, 'appId')
