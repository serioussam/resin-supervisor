Promise = require 'bluebird'
m = require 'mochainon'

{ stub } = m.sinon
m.chai.use(require('chai-events'))
{ expect } = m.chai

prepare = require './lib/prepare'
DeviceState = require '../src/device-state'
DB = require('../src/db')
Config = require('../src/config')

targetState1 = {
	local: {
		name: 'aDeviceWithDifferentName'
		config: {
			'RESIN_HOST_CONFIG_gpu_mem': '512'
			'RESIN_HOST_LOG_TO_DISPLAY': '1'
		}
		apps: [
			{
				appId: '1234'
				name: 'superapp'
				commit: 'afafafa'
				buildId: '2'
				config: {}
				services: [
					{
						appId: '1234'
						serviceId: '23'
						serviceName: 'aservice'
						containerId: '12345'
						image: 'registry2.resin.io/superapp/edfabc:latest'
						config: {}
						environment: {
							'FOO': 'bar'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						volumes: [
							'/resin-data/1234/services/23:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						labels: {}
						running: true
					},
					{
						appId: '1234'
						serviceId: '24'
						serviceName: 'anotherService'
						containerId: '12346'
						image: 'registry2.resin.io/superapp/afaff:latest'
						config: {}
						environment: {
							'FOO': 'bro'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						volumes: [
							'/resin-data/1234/services/24:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						labels: {}
						running: true
					}
				]
				volumes: {}
				networks: {}
			}
		]
	}
	dependent: { apps: [], devices: [] }
}

targetState2 = {
	local: {
		name: 'aDeviceWithDifferentName'
		config: {
			'RESIN_HOST_CONFIG_gpu_mem': '512'
			'RESIN_HOST_LOG_TO_DISPLAY': '1'
		}
		apps: [
			{
				appId: '1234'
				name: 'superapp'
				commit: 'afafafa'
				buildId: '2'
				config: {}
				services: [
					{
						appId: '1234'
						serviceId: '23'
						serviceName: 'aservice'
						containerId: '12345'
						image: 'registry2.resin.io/superapp/edfabc:latest'
						config: {}
						environment: {
							'FOO': 'bar'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						volumes: [
							'/resin-data/1234/services/23:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						labels: {}
						running: true
					}
				]
				volumes: {}
				networks: {}
			}
		]
	}
	dependent: { apps: [], devices: [] }
}

targetState3 = {
	local: {
		name: 'aDeviceWithDifferentName'
		config: {
			'RESIN_HOST_CONFIG_gpu_mem': '512'
			'RESIN_HOST_LOG_TO_DISPLAY': '1'
		}
		apps: [
			{
				appId: '1234'
				name: 'superapp'
				commit: 'afafafa'
				buildId: '2'
				config: {}
				services: [
					{
						appId: '1234'
						serviceId: '23'
						serviceName: 'aservice'
						containerId: '12345'
						image: 'registry2.resin.io/superapp/edfabc:latest'
						config: {}
						environment: {
							'FOO': 'bar'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						volumes: [
							'/resin-data/1234/services/23:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						labels: {}
						running: true
					},
					{
						appId: '1234'
						serviceId: '24'
						serviceName: 'anotherService'
						containerId: '12346'
						image: 'registry2.resin.io/superapp/foooo:latest'
						config: {}
						dependsOn: [ 'aservice' ]
						environment: {
							'FOO': 'bro'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						volumes: [
							'/resin-data/1234/services/24:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						labels: {}
						running: true
					}
				]
				volumes: {}
				networks: {}
			}
		]
	}
	dependent: { apps: [], devices: [] }
}

targetState4 = {
	local: {
		name: 'aDeviceWithDifferentName'
		config: {
			'RESIN_HOST_CONFIG_gpu_mem': '512'
			'RESIN_HOST_LOG_TO_DISPLAY': '1'
		}
		apps: [
			{
				appId: '1234'
				name: 'superapp'
				commit: 'afafafa'
				buildId: '2'
				config: {}
				services: [
					{
						appId: '1234'
						serviceId: '23'
						serviceName: 'aservice'
						containerId: '12345'
						image: 'registry2.resin.io/superapp/edfabc:latest'
						config: {}
						environment: {
							'FOO': 'bar'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						volumes: [
							'/resin-data/1234/services/23:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						labels: {}
						running: true
					},
					{
						appId: '1234'
						serviceId: '24'
						serviceName: 'anotherService'
						containerId: '12346'
						image: 'registry2.resin.io/superapp/foooo:latest'
						config: {
							'RESIN_SUPERVISOR_UPDATE_STRATEGY': 'kill-then-download'
						}
						environment: {
							'FOO': 'bro'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						volumes: [
							'/resin-data/1234/services/24:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						labels: {}
						running: true
					}
				]
				volumes: {}
				networks: {}
			}
		]
	}
	dependent: { apps: [], devices: [] }
}

targetState5 = {
	local: {
		name: 'aDeviceWithDifferentName'
		config: {
			'RESIN_HOST_CONFIG_gpu_mem': '512'
			'RESIN_HOST_LOG_TO_DISPLAY': '1'
		}
		apps: [
			{
				appId: '1234'
				name: 'superapp'
				commit: 'afafafa'
				buildId: '2'
				config: {}
				services: [
					{
						appId: '1234'
						serviceId: '23'
						serviceName: 'aservice'
						containerId: '12345'
						image: 'registry2.resin.io/superapp/edfabc:latest'
						config: {}
						environment: {
							'FOO': 'THIS VALUE CHANGED'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						volumes: [
							'/resin-data/1234/services/23:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						labels: {}
						running: true
					},
					{
						appId: '1234'
						serviceId: '24'
						serviceName: 'anotherService'
						containerId: '12346'
						image: 'registry2.resin.io/superapp/foooo:latest'
						config: {}
						dependsOn: [ 'aservice' ]
						environment: {
							'FOO': 'bro'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						volumes: [
							'/resin-data/1234/services/24:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						labels: {}
						running: true
					}
				]
				volumes: {}
				networks: {}
			}
		]
	}
	dependent: { apps: [], devices: [] }
}

targetState6 = {
	local: {
		name: 'aDeviceWithDifferentName'
		config: {
			'RESIN_HOST_CONFIG_gpu_mem': '512'
			'RESIN_HOST_LOG_TO_DISPLAY': '1'
		}
		apps: [
			{
				appId: '1234'
				name: 'superapp'
				commit: 'afafafa'
				buildId: '2'
				config: {}
				services: [
					{
						appId: '1234'
						serviceId: '23'
						serviceName: 'aservice'
						containerId: '12345'
						image: 'registry2.resin.io/superapp/edfabc:latest'
						config: {}
						environment: {
							'FOO': 'THIS VALUE CHANGED'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						volumes: [
							'/resin-data/1234/services/23:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						labels: {}
						running: true
					},
					{
						appId: '1234'
						serviceId: '24'
						serviceName: 'anotherService'
						containerId: '12346'
						image: 'registry2.resin.io/superapp/foooo:latest'
						config: {}
						environment: {
							'FOO': 'bro'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						volumes: [
							'/resin-data/1234/services/24:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						labels: {}
						running: true
					}
				]
				volumes: {}
				networks: {}
			}
		]
	}
	dependent: { apps: [], devices: [] }
}

currentState1 = {
	local: {
		name: 'aDeviceWithDifferentName'
		config: {
			'RESIN_HOST_CONFIG_gpu_mem': '512'
			'RESIN_HOST_LOG_TO_DISPLAY': '1'
		}
		apps: [
			{
				appId: '1234'
				name: 'superapp'
				commit: 'afafafa'
				buildId: '2'
				config: {}
				services: [
					{
						appId: '1234'
						serviceId: '23'
						serviceName: 'aservice'
						containerId: '12345'
						image: 'registry2.resin.io/superapp/edfabc:latest'
						config: {}
						environment: {
							'FOO': 'bar'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						volumes: [
							'/resin-data/1234/services/23:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						labels: {}
						running: true
						createdAt: new Date()
					},
					{
						appId: '1234'
						serviceId: '24'
						serviceName: 'anotherService'
						containerId: '12346'
						image: 'registry2.resin.io/superapp/afaff:latest'
						config: {}
						environment: {
							'FOO': 'bro'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						volumes: [
							'/resin-data/1234/services/24:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						labels: {}
						running: false
						createdAt: new Date()
					}
				]
				volumes: {}
				networks: {}
			}
		]
	}
	dependent: { apps: [], devices: [] }
}

currentState2 = {
	local: {
		name: 'aDeviceWithDifferentName'
		config: {
			'RESIN_HOST_CONFIG_gpu_mem': '512'
			'RESIN_HOST_LOG_TO_DISPLAY': '1'
		}
		apps: [
			{
				appId: '1234'
				name: 'superapp'
				commit: 'afafafa'
				buildId: '2'
				config: {}
				services: []
				volumes: {}
				networks: {}
			}
		]
	}
	dependent: { apps: [], devices: [] }
}

currentState3 = {
	local: {
		name: 'aDeviceWithDifferentName'
		config: {
			'RESIN_HOST_CONFIG_gpu_mem': '512'
			'RESIN_HOST_LOG_TO_DISPLAY': '1'
		}
		apps: [
			{
				appId: '1234'
				name: 'superapp'
				commit: 'afafafa'
				buildId: '2'
				config: {}
				services: [
					{
						appId: '1234'
						serviceId: '23'
						serviceName: 'aservice'
						containerId: '12345'
						image: 'registry2.resin.io/superapp/edfabc:latest'
						config: {}
						environment: {
							'FOO': 'THIS VALUE CHANGED'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						volumes: [
							'/resin-data/1234/services/23:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						labels: {}
						running: true
						createdAt: new Date()
					}
				]
				volumes: {}
				networks: {}
			}
		]
	}
	dependent: { apps: [], devices: [] }
}

currentState4 = {
	local: {
		name: 'aDeviceWithDifferentName'
		config: {
			'RESIN_HOST_CONFIG_gpu_mem': '512'
			'RESIN_HOST_LOG_TO_DISPLAY': '1'
		}
		apps: [
			{
				appId: '1234'
				name: 'superapp'
				commit: 'afafafa'
				buildId: '2'
				config: {}
				services: [
					{
						appId: '1234'
						serviceId: '23'
						serviceName: 'aservice'
						containerId: '12345'
						image: 'registry2.resin.io/superapp/edfabc:latest'
						config: {}
						environment: {
							'FOO': 'THIS VALUE CHANGED'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						volumes: [
							'/resin-data/1234/services/23:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						labels: {}
						running: true
						createdAt: new Date()
					},
					{
						appId: '1234'
						serviceId: '23'
						serviceName: 'aservice'
						containerId: '12345'
						image: 'registry2.resin.io/superapp/edfabc:latest'
						config: {}
						environment: {
							'FOO': 'THIS VALUE CHANGED'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						volumes: [
							'/resin-data/1234/services/23:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						labels: {}
						running: true
						createdAt: new Date()
					}
				]
				volumes: {}
				networks: {}
			}
		]
	}
	dependent: { apps: [], devices: [] }
}

availableImages1 = [
	{
		NormalizedRepoTags: [ 'registry2.resin.io/superapp/afaff:latest' ]
	}
	{
		NormalizedRepoTags: [ 'registry2.resin.io/superapp/edfabc:latest' ]
	}
]

availableImages2 = [
	{
		NormalizedRepoTags: [ 'registry2.resin.io/superapp/edfabc:latest' ]
	}
	{
		NormalizedRepoTags: [ 'registry2.resin.io/superapp/foooo:latest' ]
	}
]

describe 'ApplicationManager', ->
	before ->
		prepare()
		@db = new DB()
		@config = new Config({ @db })
		eventTracker = {
			track: console.log
		}
		@deviceState = new DeviceState({ @db, @config, eventTracker })
		@application = @deviceState.application
		stub(@application.images, 'get').callsFake (imageName) ->
			Promise.resolve({
				Config: {
					Env: []
					Labels: {}
					Volumes: []
				}
			})
		@db.init()
		.then =>
			@config.init()

	after ->
		@application.images.get.restore()

	it 'infers a start step when all that changes is a running state', ->
		steps = @application._inferNextSteps([], availableImages1, currentState1, targetState1, [])
		expect(steps).to.eventually.deep.equal([{
			action: 'start'
			current: currentState1.local.apps[0].services[1]
			target: targetState1.local.apps[0].services[1]
			serviceId: '24'
		}])

	it 'infers a kill step when a service has to be removed', ->
		steps = @application._inferNextSteps([], availableImages1, currentState1, targetState2, [])
		expect(steps).to.eventually.deep.equal([{
			action: 'kill'
			current: currentState1.local.apps[0].services[1]
			target: null
			serviceId: '24'
			options:
				removeImage: true
				isRemoval: true
		}])

	it 'infers a fetch step when a service has to be updated', ->
		steps = @application._inferNextSteps([], availableImages1, currentState1, targetState3, [])
		expect(steps).to.eventually.deep.equal([{
			action: 'fetch'
			current: currentState1.local.apps[0].services[1]
			target: targetState3.local.apps[0].services[1]
			serviceId: '24'
		}])

	it 'does not infer a step when it is already in progress', ->
		steps = @application._inferNextSteps([], availableImages1, currentState1, targetState3, [{
			action: 'fetch'
			current: currentState1.local.apps[0].services[1]
			target: targetState3.local.apps[0].services[1]
			serviceId: '24'
		}])
		expect(steps).to.eventually.deep.equal([])

	it 'infers a kill step when a service has to be updated but the strategy is kill-then-download', ->
		steps = @application._inferNextSteps([], availableImages1, currentState1, targetState4, [])
		expect(steps).to.eventually.deep.equal([{
			action: 'kill'
			current: currentState1.local.apps[0].services[1]
			target: targetState4.local.apps[0].services[1]
			serviceId: '24'
			options: removeImage: false
		}])

	it 'does not infer to kill a service with default strategy if a dependency is unmet', ->
		steps = @application._inferNextSteps([], availableImages2, currentState1, targetState5, [])
		expect(steps).to.eventually.deep.equal([{
			action: 'kill'
			current: currentState1.local.apps[0].services[0]
			target: targetState5.local.apps[0].services[0]
			serviceId: '23'
			options: removeImage: false
		}])

	it 'infers to kill several services as long as there is no unmet dependency', ->
		steps = @application._inferNextSteps([], availableImages2, currentState1, targetState6, [])
		expect(steps).to.eventually.have.deep.members([
			{
				action: 'kill'
				current: currentState1.local.apps[0].services[0]
				target: targetState6.local.apps[0].services[0]
				serviceId: '23'
				options: removeImage: false
			},
			{
				action: 'kill'
				current: currentState1.local.apps[0].services[1]
				target: targetState6.local.apps[0].services[1]
				serviceId: '24'
				options: removeImage: false
			}
		])

	it 'infers to start the dependency first', ->
		steps = @application._inferNextSteps([], availableImages2, currentState2, targetState5, [])
		expect(steps).to.eventually.have.deep.members([
			{
				action: 'start'
				current: null
				target: targetState5.local.apps[0].services[0]
				serviceId: '23'
			}
		])

	it 'infers to start a service once its dependency has been met', ->
		steps = @application._inferNextSteps([], availableImages2, currentState3, targetState5, [])
		expect(steps).to.eventually.have.deep.members([
			{
				action: 'start'
				current: null
				target: targetState5.local.apps[0].services[1]
				serviceId: '24'
			}
		])

	it 'infers to remove spurious containers', ->
		steps = @application._inferNextSteps([], availableImages2, currentState4, targetState5, [])
		expect(steps).to.eventually.have.deep.members([
			{
				action: 'kill'
				current: currentState4.local.apps[0].services[1]
				target: null
				serviceId: '23'
				options:
					removeImage: false
					isRemoval: false
			},
			{
				action: 'start'
				current: null
				target: targetState5.local.apps[0].services[1]
				serviceId: '24'
			}
		])