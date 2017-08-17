Promise = require 'bluebird'
_ = require 'lodash'

containerConfig = require './container-config'
{ checkTruthy } = require './validation'

exports.appStateToDB = (app) ->
	_app = _.cloneDeep(app)
	_app.volumes ?= {}
	_app.services = _.map _app.services ? [], (service) ->
		service.appId = _app.appId
		return service
	_app.config ?= {}
	_app.networks ?= {}

	dbApp = {
		appId: _app.appId
		commit: _app.commit
		name: _app.name
		buildId: _app.buildId
		config: JSON.stringify(_app.config)
		services: JSON.stringify(_app.services)
		networks: JSON.stringify(_app.networks)
		volumes: JSON.stringify(_app.volumes)
	}
	return dbApp

exports.dependentAppStateToDB = (app) ->
	_app = _.cloneDeep(app)
	_app.environment ?= {}
	_app.config ?= {}
	dbApp = {
		appId: _app.appId
		name: _app.name
		commit: _app.commit
		buildId: _app.buildId
		parentApp: _app.parentApp
		image: _app.image
		config: JSON.stringify(_app.config)
		environment: JSON.stringify(_app.environment)
	}
	return dbApp

defaultServiceConfig = (opts, images) ->
	return (service) ->
		serviceOpts = {
			serviceName: service.serviceName
		}
		_.assign(serviceOpts, opts)
		service.environment = containerConfig.extendEnvVars(service.environment ? {}, serviceOpts)
		service.volumes = service.volumes ? []
		service.labels ?= {}
		service.privileged ?= false
		service.restartPolicy = createRestartPolicy({ name: service.restart, maximumRetryCount: null })
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
	else
		policy.MaximumRetryCount = 0
	return policy

getCommand = (service, imageInfo) ->
	if service.command?
		return service.command
	else if imageInfo?.Config?.Cmd
		return imageInfo.Config.Cmd
getEntrypoint = (service, imageInfo) ->
	if service.entrypoint?
		return service.entrypoint
	else if imageInfo?.Config?.Entrypoint
		return imageInfo.Config.Entrypoint

# TODO: map ports for any of the possible formats "container:host/protocol", port ranges, etc.
getPortsAndPortBindings = (service) ->
	ports = {}
	portBindings = {}
	if service.ports?
		_.forEach service.ports, (port) ->
			ports[port + '/tcp'] = {}
			portBindings[port + '/tcp'] = [ HostPort: port ]
	if service.expose?
		_.forEach service.expose, (port) ->
			ports[port + '/tcp'] = {}
	return { ports, portBindings }

getLabelsWithResinExtras = (service) ->
	labels = _.clone(service.labels)
	labels['io.resin.supervised'] = 'true'
	labels['io.resin.app_id'] = service.appId
	labels['io.resin.service_id'] = service.serviceId
	labels['io.resin.service_name'] = service.serviceName
	labels['io.resin.container_id'] = service.containerId
	labels['io.resin.build_id'] = service.buildId
	return labels

getBindsAndVolumes = (service) ->
	binds = containerConfig.defaultBinds(service.appId, service.serviceId)
	volumes = {}
	_.forEach service.volumes, (vol) ->
		isBind = /:/.test(vol)
		if isBind
			bindSource = vol.split(':')[0]
			if !/\//.test(bindSource)
				binds.push(vol)
			else
				console.log("Ignoring invalid bind mount #{vol}")
		else
			volumes[vol] = {}
	return { binds, volumes }

exports.serviceToContainerConfig = (service, { imageInfo, supervisorApiKey, resinApiKey, supervisorApiPort, supervisorApiHost }) ->
	cmd = getCommand(service, imageInfo)
	entrypoint = getEntrypoint(service, imageInfo)
	{ ports, portBindings } = getPortsAndPortBindings(service)
	labels = getLabelsWithResinExtras(service)
	{ binds, volumes } = getBindsAndVolumes(service)

	if checkTruthy(labels['io.resin.features.dbus'])
		binds.push('/run/dbus:/host/run/dbus')
	if checkTruthy(labels['io.resin.features.kernel_modules'])
		binds.push('/lib/modules:/lib/modules')
	if checkTruthy(labels['io.resin.features.firmware'])
		binds.push('/lib/firmware:/lib/firmware')
	if checkTruthy(labels['io.resin.features.supervisor_api'])
		service.environment['RESIN_SUPERVISOR_HOST'] = supervisorApiHost
		service.environment['RESIN_SUPERVISOR_PORT'] = supervisorApiPort
		service.environment['RESIN_SUPERVISOR_ADDRESS'] = "http://#{supervisorApiHost}:#{supervisorApiPort}"
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
		Labels: labels
		HostConfig:
			Privileged: service.privileged
			NetworkMode: service.networkMode
			PortBindings: portBindings
			Binds: binds
			RestartPolicy: service.restartPolicy
	}
	return conf

exports.containerToService = (container) ->
	featureBinds = [
		'/run/dbus:/host/run/dbus'
		'/lib/modules:/lib/modules'
		'/lib/firmware:/lib/firmware'
	]
	if container.State.Running
		state = 'Idle'
	else
		state = 'Stopped'
	labelsToOmit = [ 'io.resin.supervised', 'io.resin.service_id', 'io.resin.service_name', 'io.resin.container_id', 'io.resin.build_id', 'io.resin.app_id' ]

	boundContainerPorts = []
	ports = []
	expose = []
	_.forEach container.HostConfig.PortBindings, (conf, port) ->
		containerPort = port.match(/^([0-9]*)\/tcp$/)?[1]
		if containerPort?
			boundContainerPorts.push(containerPort)
			hostPort = conf[0]?.HostPort
			if !_.isEmpty(hostPort)
				ports.push("#{containerPort}:#{hostPort}")
			else
				ports.push(containerPort)
	_.forEach container.Config.ExposedPorts, (_, port) ->
		containerPort = port.match(/^([0-9]*)\/tcp$/)?[1]
		if containerPort? and !_.includes(boundContainerPorts, containerPort)
			expose.push(containerPort)

	appId = container.Config.Labels['io.resin.app_id']
	serviceId = container.Config.Labels['io.resin.service_id']
	service = {
		appId: appId
		serviceId: serviceId
		serviceName: container.Config.Labels['io.resin.service_name']
		containerId: container.Config.Labels['io.resin.container_id']
		command: container.Config.Cmd
		entrypoint: container.Config.Entrypoint
		networkMode: container.HostConfig.NetworkMode
		volumes: _.filter _.concat(container.HostConfig.Binds ? [], _.keys(container.Config.Volumes ? {})), (vol) ->
			return false if _.includes(containerConfig.defaultBinds(appId, serviceId), vol)
			return false if _.includes(featureBinds, vol)
			return true
		image: container.Config.Image
		environment: exports.envArrayToObject(container.Config.Env)
		privileged: container.HostConfig.Privileged
		buildId: container.Config.Labels['io.resin.build_id']
		labels: _.omit(container.Config.Labels, labelsToOmit)
		status: {
			state
			download_progress: null
		}
		running: container.State.Running
		createdAt: new Date(container.Created)
		restartPolicy: container.HostConfig.RestartPolicy
		ports: ports
		expose: expose
		dockerContainerId: container.Id
	}
	_.pull(service.volumes, containerConfig.defaultBinds(service.appId, service.serviceId))
	return service

exports.appsArrayToObject = (apps) ->
	_.keyBy(apps, 'appId')
