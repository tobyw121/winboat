<template>
    <div class="flex flex-col gap-10 overflow-x-hidden" :class="{ 'hidden': !maxNumCores }">
        <div>
            <x-label class="mb-4 text-neutral-300">Container</x-label>
            <div class="flex flex-col gap-4">
                <!-- RAM Allocation -->
                <x-card
                    class="flex flex-row justify-between items-center p-2 py-3 my-0 w-full backdrop-blur-xl backdrop-brightness-150 bg-neutral-800/20">
                    <div>
                        <div class="flex flex-row gap-2 items-center mb-2">
                            <Icon class="inline-flex text-violet-400 size-8" icon="game-icons:ram"></Icon>
                            <h1 class="my-0 text-lg font-semibold">
                                RAM Allocation
                            </h1>
                        </div>
                        <p class="text-neutral-400 text-[0.9rem] !pt-0 !mt-0">
                            How many gigabytes of RAM are allocated to the Windows virtual machine
                        </p>
                    </div>
                    <div class="flex flex-row gap-2 justify-center items-center">
                        <x-input
                            class="max-w-16 text-right text-[1.1rem]"
                            min="4"
                            :max="maxRamGB"
                            :value="ramGB"
                            @input="(e: any) => ramGB = Number(/^\d+$/.exec(e.target.value)![0] || 4)"
                            required
                        ></x-input>
                        <p class="text-neutral-100">GB</p>
                    </div>
                </x-card>

                <!-- CPU Cores -->
                <x-card
                    class="flex flex-row justify-between items-center p-2 py-3 my-0 w-full backdrop-blur-xl backdrop-brightness-150 bg-neutral-800/20">
                    <div>
                        <div class="flex flex-row gap-2 items-center mb-2">
                            <Icon class="inline-flex text-violet-400 size-8" icon="solar:cpu-bold"></Icon>
                            <h1 class="my-0 text-lg font-semibold">
                                CPU Cores
                            </h1>
                        </div>
                        <p class="text-neutral-400 text-[0.9rem] !pt-0 !mt-0">
                            How many CPU Cores are allocated to the Windows virtual machine
                        </p>
                    </div>
                    <div class="flex flex-row gap-2 justify-center items-center">
                        <x-input
                            class="max-w-16 text-right text-[1.1rem]"
                            min="2"
                            :max="maxNumCores"
                            :value="numCores"
                            @input="(e: any) => numCores = Number(/^\d+$/.exec(e.target.value)![0] || 4)"
                            required
                        ></x-input>
                        <p class="text-neutral-100">Cores</p>
                    </div>
                </x-card>

                <!-- Helios Acceleration -->
                <x-card
                    class="flex flex-row justify-between items-center p-2 py-3 my-0 w-full backdrop-blur-xl backdrop-brightness-150 bg-neutral-800/20"
                >
                    <div>
                        <div class="flex flex-row gap-2 items-center mb-2">
                            <Icon class="inline-flex text-violet-400 size-8" icon="mdi:gpu"></Icon>
                            <h1 class="my-0 text-lg font-semibold">
                                Helios Acceleration
                            </h1>
                        </div>
                        <p class="text-neutral-400 text-[0.9rem] !pt-0 !mt-0">
                            On an existing VM, switch the adapter here, then install the bundled HeliosSetup.exe through the Browser Display console. Experimental GPU sharing uses the host's <span class="font-mono bg-neutral-700 rounded-md px-1 py-0.5">/dev/dri</span> devices.
                        </p>
                        <p
                            v-if="!heliosSupportAvailable && !heliosEnabled"
                            class="text-sm text-red-400 !pt-0 !mt-1"
                        >
                            No compatible render devices were detected. Helios cannot be enabled on this system.
                        </p>
                    </div>
                    <div class="flex flex-row justify-center items-center gap-2">
                        <x-switch
                            :toggled="heliosEnabled"
                            :disabled="!heliosSupportAvailable && !heliosEnabled"
                            @toggle="toggleHelios"
                            size="large"
                        ></x-switch>
                    </div>
                </x-card>

                <x-card v-if="heliosEnabled" class="flex flex-row justify-between items-center p-3 my-0 bg-neutral-800/20">
                    <div>
                        <h1 class="text-lg font-semibold my-0 mb-2">Local desktop (experimental)</h1>
                        <p class="text-neutral-400 text-[0.9rem] !pt-0 !mt-0">
                            Open Windows in a native window. Requires GTK4. Disable this option and save to use Browser Display.
                            Applying a display change restarts the VM. Audio and captured gaming mouse input are not included yet.
                            Host boot auto-start is disabled when this mode is enabled. Start the VM from your desktop session.
                        </p>
                    </div>
                    <div class="flex flex-col gap-2 items-end">
                        <x-switch :toggled="localDisplayEnabled" :disabled="isApplyingChanges" @toggle="toggleLocalDisplay" size="large"></x-switch>
                        <x-button v-if="origLocalDisplayEnabled && compose?.services.windows.environment.HELIOS_DISPLAY === 'dbus'" :disabled="isApplyingChanges || localDisplayState === 'opening'" @click="openLocalDesktop()">Open Local Desktop</x-button>
                        <x-button v-else-if="origLocalDisplayEnabled" :disabled="isApplyingChanges" @click="saveDockerCompose()">Retry Local Desktop</x-button>
                        <span v-if="localDisplayMessage" class="text-sm text-neutral-400 max-w-sm">{{ localDisplayMessage }}</span>
                    </div>
                </x-card>

                <x-card v-if="heliosEnabled" class="p-4 my-0 w-full bg-neutral-800/20">
                    <h1 class="text-lg font-semibold mb-2">Windows resolution</h1>
                    <p class="text-neutral-400 text-sm">Choose the startup resolution for Helios and VGA. Saving restarts the VM. Local Desktop scales the picture to its window; zoom does not change the Windows resolution.</p>
                    <div class="flex items-center gap-3 mt-3">
                        <select v-model="resolution" aria-label="Windows startup resolution" :disabled="isApplyingChanges" class="rounded bg-neutral-900 p-2">
                            <option v-for="mode in HELIOS_RESOLUTIONS" :key="mode.key" :value="mode.key">{{ mode.label }}</option>
                        </select>
                        <x-button :disabled="isApplyingChanges || !origHeliosEnabled || resolution === origResolution" @click="saveResolution">Save resolution and restart</x-button>
                    </div>
                    <p v-if="resolutionMessage" class="text-sm text-neutral-400 mt-2">{{ resolutionMessage }}</p>
                </x-card>

                <x-card class="p-4 my-0 w-full bg-neutral-800/20">
                    <h1 class="text-lg font-semibold mb-3">Shared Folders</h1>
                    <SharedFolders v-model="sharedFolders" :disabled="isApplyingChanges" />
                    <div class="mt-4 flex gap-3 items-center">
                        <x-button :disabled="isApplyingChanges || !sharesNeedSaving || !!sharedFolderErrors(sharedFolders).length" @click="saveShares">Save shared folders</x-button>
                        <span class="text-sm text-neutral-400">Applies these folders and restarts the VM.</span>
                    </div>
                    <p v-if="shareSaveMessage" class="text-sm mt-2" role="status">{{ shareSaveMessage }}</p>
                    <div class="mt-4 flex gap-3 items-center"><x-button :disabled="isApplyingChanges || checkingShares || !sharedFolders.some(folder => folder.enabled) || winboat.containerStatus.value !== ContainerStatus.Running || JSON.stringify(sharedFolders) !== origSharedFolders || !compose?.services.windows['x-winboat-shared-folders']" @click="testShares">Test saved shares</x-button><span class="text-sm text-neutral-400">Save changes and start the VM before testing.</span></div>
                    <div v-for="result in shareResults" :key="result.name" class="text-sm mt-2" :class="result.ok ? 'text-green-300' : 'text-red-300'">
                        <p>{{ result.name }}: {{ result.message }}</p><div v-if="result.windowsPath" class="flex gap-2 items-center"><code>{{ result.windowsPath }}</code><x-button @click="copyWindowsPath(result.windowsPath)">Copy direct path</x-button></div>
                    </div>
                    <p v-if="shareTestError" class="text-sm text-red-300 mt-2">{{ shareTestError }}</p>
                </x-card>

                <!-- Auto Start Container -->
                <x-card class="flex relative z-20 flex-row justify-between items-center p-2 py-3 my-0 w-full backdrop-blur-xl backdrop-brightness-150 bg-neutral-800/20">
                    <div>
                        <div class="flex flex-row items-center gap-2 mb-2">
                            <Icon class="text-violet-400 inline-flex size-8" icon="clarity:power-solid"></Icon>
                            <h1 class="text-lg my-0 font-semibold">
                                Auto Start Container
                            </h1>
                        </div>
                        <p class="text-neutral-400 text-[0.9rem] !pt-0 !mt-0">
                            If enabled, the Windows container starts when the system boots. Unavailable while Local Desktop is selected.
                        </p>
                    </div>
                    <div class="flex flex-row justify-center items-center gap-2">
                        <x-switch
                            :toggled="autoStartContainer"
                            :disabled="heliosEnabled && localDisplayEnabled"
                            @toggle="(_: any) => autoStartContainer = !autoStartContainer"
                            size="large"
                        ></x-switch>
                    </div>
                </x-card>

                <!-- FreeRDP Port -->
                <x-card
                    class="flex items-center p-2 flex-row justify-between w-full py-3 my-0 bg-neutral-800/20 backdrop-brightness-150 backdrop-blur-xl">
                    <div>
                        <div class="flex flex-row items-center gap-2 mb-2">
                            <Icon class="text-violet-400 inline-flex size-8" icon="lucide:ethernet-port"></Icon>
                            <h1 class="text-lg my-0 font-semibold">
                                FreeRDP Port
                            </h1>
                        </div>
                        <p class="text-neutral-400 text-[0.9rem] !pt-0 !mt-0">
                            You can change what port FreeRDP uses to communicate with the VM
                        </p>
                    </div>
                    <div class="flex flex-row justify-center items-center gap-2">
                        <x-input
                            class="max-w-16 text-right text-[1.1rem]"
                            min="0"
                            :max="PORT_MAX"
                            :value="freerdpPort"
                            @input="(e: any) => freerdpPort = Number(/^\d+$/.exec(e.target.value)![0] || winboat.getHostPort(GUEST_RDP_PORT))"
                            required
                        ></x-input>
                    </div>
                </x-card>
                <div class="flex flex-col">
                    <p class="my-0 text-red-500" v-for="error, k of errors" :key="k">
                        ❗ {{ error }}
                    </p>
                </div>
                <x-button
                    :disabled="saveButtonDisabled || isUpdatingUSBPrerequisites"
                    @click="saveDockerCompose()"
                    class="w-24"
                >
                    <span v-if="!isApplyingChanges || isUpdatingUSBPrerequisites">Save</span>
                    <x-throbber v-else class="w-10"></x-throbber>
                </x-button>
                <p v-if="saveButtonDisabled && !isApplyingChanges && errors.length" class="text-sm text-red-300">{{ errors.join(' ') }} Shared folders can be saved separately above.</p>
            </div>
        </div>
        <div v-show="wbConfig.config.experimentalFeatures" :key="rerenderExperimental">
            <x-label class="mb-4 text-neutral-300">Devices</x-label>
            <div class="flex flex-col gap-4">
                <!-- USB Passthrough -->
                <x-card class="flex relative z-20 flex-row justify-between items-center p-2 py-3 my-0 w-full backdrop-blur-xl backdrop-brightness-150 bg-neutral-800/20">
                    <div class="w-full">
                        <div class="flex flex-row gap-2 items-center mb-2">
                            <Icon class="inline-flex text-violet-400 size-8" icon="fluent:tv-usb-24-filled"></Icon>
                            <h1 class="my-0 text-lg font-semibold">
                                USB Passthrough
                                <span class="bg-violet-500 rounded-full px-3 py-0.5 text-sm ml-2">
                                    Experimental
                                </span>
                            </h1>
                        </div>
                        <template v-if="usbPassthroughDisabled || isUpdatingUSBPrerequisites">
                            <x-card 
                                class="flex items-center py-2 w-full my-2 backdrop-blur-xl gap-4 backdrop-brightness-150 bg-yellow-200/10"
                            >
                                <Icon class="inline-flex text-yellow-500 size-8" icon="clarity:warning-solid"></Icon>
                                <h1 class="my-0 text-base font-normal text-yellow-200">
                                    We need to update your Docker Compose in order to use this feature!
                                </h1>

                                <x-button 
                                    :disabled="isUpdatingUSBPrerequisites"
                                    class="mt-1 !bg-gradient-to-tl from-yellow-200/20 to-transparent ml-auto hover:from-yellow-300/30 transition !border-0"
                                    @click="addRequiredComposeFieldsUSB"
                                >
                                    <x-label
                                        class="ext-lg font-normal text-yellow-200"
                                        v-if="!isUpdatingUSBPrerequisites"
                                    >
                                        Update
                                    </x-label>

                                    <x-throbber v-else class="w-8 text-yellow-300"></x-throbber>
                                </x-button>
                            </x-card>
                        </template>
                        <template v-else>
                            <x-label 
                                class="text-neutral-400 text-[0.9rem] !pt-0 !mt-0" 
                                v-if="usbManager.ptDevices.value.length == 0"
                            >
                                Press the button below to add USB devices to your passthrough list
                            </x-label>
                            <TransitionGroup name="devices" tag="x-box" class="flex-col gap-2 mt-4">
                                <x-card 
                                    class="flex justify-between items-center px-2 py-0 m-0 bg-white/5"
                                    v-for="device of usbManager.ptDevices.value" 
                                    :key="`${device.vendorId}-${device.productId}`"
                                    :class="{ 'bg-white/[calc(0.05*0.75)] [&_*:not(div):not(span)]:opacity-75': !usbManager.isPTDeviceConnected(device) }"
                                >
                                    <div class="flex flex-row gap-2 items-center"> 
                                        <span v-if="usbManager.isMTPDevice(device) || usbManager.stringifyPTSerializableDevice(device).toLowerCase().includes('mtp')" class="relative group">
                                            <Icon icon="clarity:warning-solid" class="text-yellow-300 size-7 cursor-pointer" />
                                            <span
                                                class="absolute bottom-5 z-50 w-[320px] bg-neutral-800/90 backdrop-blur-sm text-xs text-gray-300 rounded-lg shadow-lg px-3 py-2
                                                hidden group-hover:block transition-opacity duration-200 pointer-events-none" 
                                            >
                                                This device appears to be using the MTP protocol, which is known for being problematic.
                                                Some Desktop Environments automatically mount MTP devices, which in turn causes WinBoat to not be able 
                                                to pass the device through.
                                            </span>
                                        </span>

                                        <span v-if="!usbManager.isPTDeviceConnected(device)" class="relative group">
                                            <Icon icon="ix:connection-fail" class="text-red-500 size-7 cursor-pointer" />
                                            <span
                                                class="absolute bottom-5 z-50 w-[320px] bg-neutral-800/90 backdrop-blur-sm text-xs text-gray-300 rounded-lg shadow-lg px-3 py-2
                                                hidden group-hover:block transition-opacity duration-200 pointer-events-none" 
                                            >
                                                This device is currently not connected.
                                            </span>
                                        </span>

                                        <p class="text-base !m-0 text-gray-200">
                                            {{ usbManager.stringifyPTSerializableDevice(device) }}
                                        </p>
                                    </div>
                                    <x-button @click="removeDevice(device)" class="mt-1 !bg-gradient-to-tl from-red-500/20 to-transparent hover:from-red-500/30 transition !border-0">
                                        <x-icon href="#remove"></x-icon>
                                    </x-button>
                                </x-card>
                            </TransitionGroup>
                            <x-button 
                                v-if="availableDevices.length > 0"
                                class="!bg-gradient-to-tl from-blue-400/20 shadow-md shadow-blue-950/20 to-transparent hover:from-blue-400/30 transition"
                                :class="{ 'mt-4': usbManager.ptDevices.value.length }"
                                @click="refreshAvailableDevices()"
                            >
                                <x-icon href="#add"></x-icon>
                                <x-label>Add Device</x-label>
                                <TransitionGroup ref="usbMenu" name="menu" tag="x-menu" class="max-h-52">
                                    <x-menuitem 
                                        v-for="device, k of availableDevices as Device[]" 
                                        :key="device.portNumbers.join(',')"
                                        @click="addDevice(device)"
                                    >
                                        <x-label>{{ usbManager.stringifyDevice(device) }}</x-label>
                                    </x-menuitem>
                                    <x-menuitem v-if="availableDevices.length === 0" disabled>
                                        <x-label>No available devices</x-label>
                                    </x-menuitem>
                                </TransitionGroup>
                            </x-button>
                        </template>
                    </div>
                </x-card>
            </div>
        </div>
        <div>
            <x-label class="mb-4 text-neutral-300">General</x-label>
            <div class="flex flex-col gap-4">
                <!-- Display Scaling -->
                <x-card
                    class="flex relative z-10 flex-row justify-between items-center p-2 py-3 my-0 w-full backdrop-blur-xl backdrop-brightness-150 bg-neutral-800/20">
                    <div>
                        <div class="flex flex-row gap-2 items-center mb-2">
                            <Icon class="inline-flex text-violet-400 size-8" icon="uil:scaling-right"></Icon>
                            <h1 class="my-0 text-lg font-semibold">
                                Display Scaling
                            </h1>
                        </div>
                        <p class="text-neutral-400 text-[0.9rem] !pt-0 !mt-0">
                            Controls how large the display scaling is.
                        </p>
                    </div>
                    <div class="flex flex-row gap-2 justify-center items-center">
                        <x-select class="w-20" @change="(e: any) => wbConfig.config.scale = Number(e.detail.newValue)">
                            <x-menu>
                                <x-menuitem value="100" :toggled="wbConfig.config.scale === 100">
                                    <x-label>100%</x-label>
                                </x-menuitem>

                                <x-menuitem value="140" :toggled="wbConfig.config.scale === 140">
                                    <x-label>140%</x-label>
                                </x-menuitem>

                                <x-menuitem value="180" :toggled="wbConfig.config.scale === 180">
                                    <x-label>180%</x-label>
                                </x-menuitem>
                            </x-menu>
                        </x-select>
                    </div>
                </x-card>

                <x-card
                    class="flex relative z-10 flex-row justify-between items-center p-2 py-3 my-0 w-full backdrop-blur-xl backdrop-brightness-150 bg-neutral-800/20">
                    <div>
                        <div class="flex flex-row gap-2 items-center mb-2">
                            <Icon class="inline-flex text-violet-400 size-8" icon="uil:apps"></Icon>
                            <h1 class="my-0 text-lg font-semibold">
                                Application Scaling
                            </h1>
                        </div>
                        <p class="text-neutral-400 text-[0.9rem] !pt-0 !mt-0">
                            Controls how large the application scaling is.
                        </p>
                    </div>
                    <div class="flex flex-row gap-2 justify-center items-center">
                        <x-button type="button" class="px-2 py-1 text-neutral-200" @click="updateApplicationScale(wbConfig.config.scaleDesktop - 10)">-</x-button>
                        <x-input
                            type="text"
                            v-model="origApplicationScale"
                            class="w-20"
                            v-on:keydown="(e: any) => ensureNumericInput(e)"
                            v-on:blur="(e: any) => updateApplicationScale(e.target.value)"
                        ></x-input>
                        <x-button type="button" class="px-2 py-1" @click="updateApplicationScale(wbConfig.config.scaleDesktop + 10)">+</x-button>
                    </div>
                </x-card>

                <!-- Multi Monitor -->
                <x-card
                    class="flex relative z-10 flex-row justify-between items-center p-2 py-3 my-0 w-full backdrop-blur-xl backdrop-brightness-150 bg-neutral-800/20">
                    <div>
                        <div class="flex flex-row gap-2 items-center mb-2">
                            <Icon class="inline-flex text-violet-400 size-8" icon="uil:monitor"></Icon>
                            <h1 class="my-0 text-lg font-semibold">
                                Multi-Monitor Support
                            </h1>
                        </div>
                        <p class="text-neutral-400 text-[0.9rem] !pt-0 !mt-0">
                            Controls how multiple monitors are handled. MultiMon creates separate displays for each monitor, while Span stretches the display across all monitors. Note: Span or MultiMon may work better depending on your setup.
                        </p>
                    </div>
                    <div class="flex flex-row gap-2 justify-center items-center">
                        <x-select class="w-20" @change="(e: any) => wbConfig.config.multiMonitor = Number(e.detail.newValue)">
                            <x-menu>
                                <x-menuitem value="0" :toggled="wbConfig.config.multiMonitor === 0">
                                    <x-label>None</x-label>
                                </x-menuitem>

                                <x-menuitem value="1" :toggled="wbConfig.config.multiMonitor === 1">
                                    <x-label>MultiMon</x-label>
                                </x-menuitem>

                                <x-menuitem value="2" :toggled="wbConfig.config.multiMonitor === 2">
                                    <x-label>Span</x-label>
                                </x-menuitem>
                            </x-menu>
                        </x-select>
                    </div>
                </x-card>

                <!-- Smartcard Passthrough -->
                <x-card
                    class="flex flex-row justify-between items-center p-2 py-3 my-0 w-full backdrop-blur-xl backdrop-brightness-150 bg-neutral-800/20">
                    <div>
                        <div class="flex flex-row gap-2 items-center mb-2">
                            <Icon class="inline-flex text-violet-400 size-8" icon="game-icons:swipe-card"></Icon>
                            <h1 class="my-0 text-lg font-semibold">
                                Smartcard Passthrough
                            </h1>
                        </div>
                        <p class="text-neutral-400 text-[0.9rem] !pt-0 !mt-0">
                            If enabled, your smartcard readers will be passed to Windows when you start an app
                        </p>
                    </div>
                    <div class="flex flex-row gap-2 justify-center items-center">
                        <x-switch
                            :toggled="wbConfig.config.smartcardEnabled"
                            @toggle="(_: any) => wbConfig.config.smartcardEnabled = !wbConfig.config.smartcardEnabled"
                            size="large"
                        ></x-switch>
                    </div>
                </x-card>

                <!-- RDP Monitoring -->
                <x-card
                    class="flex flex-row justify-between items-center p-2 py-3 my-0 w-full backdrop-blur-xl backdrop-brightness-150 bg-neutral-800/20">
                    <div>
                        <div class="flex flex-row gap-2 items-center mb-2">
                            <Icon class="inline-flex text-violet-400 size-8" icon="fluent:remote-16-filled"></Icon>
                            <h1 class="my-0 text-lg font-semibold">
                                RDP Monitoring
                            </h1>
                        </div>
                        <p class="text-neutral-400 text-[0.9rem] !pt-0 !mt-0">
                            If enabled, a banner will appear when the RDP session is connected (may cause high CPU usage, disable if you notice performance issues)
                        </p>
                    </div>
                    <div class="flex flex-row gap-2 justify-center items-center">
                        <x-switch
                            :toggled="wbConfig.config.rdpMonitoringEnabled"
                            @toggle="(_: any) => wbConfig.config.rdpMonitoringEnabled = !wbConfig.config.rdpMonitoringEnabled"
                            size="large"
                        ></x-switch>
                    </div>
                </x-card>
            </div>
        </div>

        <div>
            <x-label class="mb-4 text-neutral-300">WinBoat</x-label>

            <!-- Experimental Features -->
            <x-card
                class="flex items-center p-2 flex-row justify-between w-full py-3 my-0 bg-neutral-800/20 backdrop-brightness-150 backdrop-blur-xl">
                <div>
                    <div class="flex flex-row items-center gap-2 mb-2">
                        <Icon class="text-violet-400 inline-flex size-8" icon="streamline-ultimate:lab-tube-experiment"></Icon>
                        <h1 class="text-lg my-0 font-semibold">
                            Experimental Features
                        </h1>
                    </div>
                    <p class="text-neutral-400 text-[0.9rem] !pt-0 !mt-0">
                        If enabled, you'll have access to experimental features that may not be stable or complete
                    </p>
                </div>
                <div class="flex flex-row justify-center items-center gap-2">
                    <x-switch
                        :toggled="wbConfig.config.experimentalFeatures"
                        @toggle="toggleExperimentalFeatures"
                        size="large"
                    ></x-switch>
                </div>
            </x-card>
        </div>

        <div>
            <x-label class="mb-4 text-neutral-300">Danger Zone</x-label>
            <x-card class="flex flex-col py-3 my-0 mb-6 w-full backdrop-blur-xl backdrop-brightness-150 bg-red-500/10">
                <h1 class="my-0 text-lg font-normal text-red-300">
                    ⚠️ <span class="font-bold">WARNING:</span> All actions here are potentially destructive, proceed at your own caution!
                </h1>
            </x-card>
            <div>

            </div>
            <x-button
                class="!bg-red-800/20 px-4 py-1 !border-red-500/10 generic-hover flex flex-row items-center gap-2 !text-red-300"
                @click="resetWinboat()"
                :disabled="isResettingWinboat"
            >
                <Icon v-if="resetQuestionCounter < 3" icon="mdi:bomb" class="size-8"></Icon>
                <x-throbber v-else class="size-8"></x-throbber>

                <span v-if="resetQuestionCounter === 0">Reset Winboat & Remove VM</span>
                <span v-else-if="resetQuestionCounter === 1">Are you sure? This action cannot be undone.</span>
                <span v-else-if="resetQuestionCounter === 2">One final check, are you ABSOLUTELY sure?</span>
                <span v-else-if="resetQuestionCounter === 3">Resetting Winboat...</span>
            </x-button>
        </div>
    </div>
</template>

<script setup lang="ts">
import SharedFolders from '../components/SharedFolders.vue';
import {sharedFolderErrors, type SharedFolder} from '../../shared/shared-folders';
import {changedResourceErrors} from '../../shared/configuration-resources';
import {configuredSharedFolders, prepareSharedFolders, checkSharedFolders, type ShareCheck} from '../lib/shared-folders';
import { configureHelios, HELIOS_IMAGE } from '../../shared/helios';
import { HELIOS_RESOLUTIONS, DEFAULT_HELIOS_RESOLUTION, heliosResolution, configureHeliosResolution } from '../../shared/helios-resolution';
import { requireHelios } from '../lib/helios';
import { resolveHeliosDisplay } from '../../shared/helios-display';
import { requireLocalDisplay, prepareLocalDisplay, localDisplayDirectory, openLocalDesktop, localDisplayState, localDisplayMessage } from '../lib/helios-display';

import { computed, onMounted, ref } from 'vue';
import { ContainerStatus, Winboat } from '../lib/winboat';
import type { ComposeConfig } from '../../types';
import { getSpecs } from '../lib/specs';
import { Icon } from '@iconify/vue';
import { WinboatConfig } from '../lib/config';
import { USBManager, type PTSerializableDeviceInfo } from '../lib/usbmanager';
import { type Device } from "usb";
import {
    PORT_MAX,
    USB_VID_BLACKLIST,
    RESTART_ON_FAILURE,
    RESTART_NO,
    GUEST_RDP_PORT,
    GUEST_API_PORT,
    GUEST_NOVNC_PORT,
    DEFAULT_HOST_QMP_PORT,
} from '../lib/constants';
import { PortManager } from '../utils/port';
import { checkHeliosSupport } from '../utils/gpu';
const { app }: typeof import('@electron/remote') = require('@electron/remote');

// Emits
const $emit = defineEmits(["rerender"]);

const winboat = new Winboat();
const usbManager = new USBManager();

// Constants
const USB_BUS_PATH = "/dev/bus/usb:/dev/bus/usb";
const QMP_ARGUMENT = "-qmp tcp:0.0.0.0:7149,server,wait=off"; // 7149 can remain hardcoded as it refers to a guest port
const GUEST_QMP_PORT = "7149";

// For Resources
const compose = ref<ComposeConfig | null>(null);
const numCores = ref(0);
const origNumCores = ref(0);
const maxNumCores = ref(0);
const ramGB = ref(0); 
const origRamGB = ref(0);
const maxRamGB = ref(0);
const sharedFolders = ref<SharedFolder[]>([]);
const origSharedFolders = ref('[]');
const resolution = ref(DEFAULT_HELIOS_RESOLUTION);
const origResolution = ref(DEFAULT_HELIOS_RESOLUTION);
const resolutionMessage = ref('');
async function saveResolution() {
    if (isApplyingChanges.value) return;
    isApplyingChanges.value = true; resolutionMessage.value = '';
    try {
        await requireHelios();
        const next = winboat.parseCompose();
        next.services.windows = configureHeliosResolution(next.services.windows, resolution.value);
        await winboat.replaceCompose(next);
        compose.value = winboat.parseCompose();
        origResolution.value = heliosResolution(compose.value.services.windows);
        resolutionMessage.value = 'Startup resolution saved. Windows is restarting with the selected size.';
    } catch (error) {resolutionMessage.value = error instanceof Error ? error.message : String(error);}
    finally {isApplyingChanges.value = false;}
}
const checkingShares = ref(false);
const shareResults = ref<ShareCheck[]>([]);
const shareTestError = ref('');
const shareSaveMessage = ref('');
const sharesNeedSaving = computed(() => JSON.stringify(sharedFolders.value) !== origSharedFolders.value ||
    (!compose.value?.services.windows['x-winboat-shared-folders'] && sharedFolders.value.some(folder => folder.enabled)));
async function saveShares() {
    if (isApplyingChanges.value) return;
    isApplyingChanges.value = true;
    shareSaveMessage.value = '';shareResults.value = [];shareTestError.value = '';
    try {
        // Read the saved service, preserving graphics, CPU, RAM and pending
        // unrelated form edits. Do not reconfigure the graphics adapter here.
        const next = winboat.parseCompose();
        next.services.windows = await prepareSharedFolders(next.services.windows, sharedFolders.value);
        await winboat.replaceCompose(next);
        compose.value = winboat.parseCompose();
        sharedFolders.value = configuredSharedFolders(compose.value.services.windows);
        origSharedFolders.value = JSON.stringify(sharedFolders.value);
        shareSaveMessage.value = 'Shared folders saved. The VM has been restarted; use Test saved shares when it is running.';
    } catch (error) {
        shareSaveMessage.value = error instanceof Error ? error.message : String(error);
    } finally {isApplyingChanges.value = false;}
}
function copyWindowsPath(value:string) {const {clipboard}:typeof import('electron')=require('electron');clipboard.writeText(value);}
async function testShares() {
    checkingShares.value=true;shareTestError.value='';shareResults.value=[];
    try {shareResults.value=await checkSharedFolders();}
    catch(error) {shareTestError.value=error instanceof Error ? error.message : String(error);}
    finally {checkingShares.value=false;}
}
const origAutoStartContainer = ref(false);
const autoStartContainer = ref(false);
const freerdpPort = ref(0);
const origFreerdpPort = ref(0);
const isApplyingChanges = ref(false);
const resetQuestionCounter = ref(0);
const isResettingWinboat = ref(false);
const isUpdatingUSBPrerequisites = ref(false);
const origApplicationScale = ref(0);
const heliosEnabled = ref(false);
const origHeliosEnabled = ref(false);
const localDisplayEnabled = ref(false);
async function toggleLocalDisplay() {
    localDisplayEnabled.value = !localDisplayEnabled.value;
    localDisplayMessage.value = '';
    if (localDisplayEnabled.value) {
        autoStartContainer.value = false;
        try { await requireLocalDisplay(); }
        catch (error) { localDisplayMessage.value = `Selection can be saved. Browser Display will remain active: ${error instanceof Error ? error.message : String(error)}`; }
    }
}
const origLocalDisplayEnabled = ref(false);
const heliosSupportAvailable = ref(checkHeliosSupport());

// For USB Devices
const availableDevices = ref<Device[]>([]);
const rerenderExperimental = ref(0);
// ^ This ref is needed because reactivity fails on wbConfig. 
//   We manually increment this value in toggleExperimentalFeatures() to force rerender.

// For handling the QMP port, as we can't rely on the winboat instance doing this for us.
// A great example is when the container is offline. In that case, winboat's portManager isn't instantiated.
let qmpPortManager = ref<PortManager | null>(null);
// ^ Has to be reactive for usbPassthroughDisabled computed to trigger.

// For General
const wbConfig = new WinboatConfig();

onMounted(async () => {
    await assignValues();
});

function ensureNumericInput(e: any) {
    if (e.metaKey || e.ctrlKey || e.which <= 0 || e.which === 8 || e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
        return;
    }

    if (!/[0-9]/.test(e.key)) {
        e.preventDefault();
    }
}

function toggleHelios() {
    if (!heliosSupportAvailable.value && !heliosEnabled.value) {
        return;
    }

    heliosEnabled.value = !heliosEnabled.value;
}

function updateApplicationScale(value: string | number) {
    let val = typeof value === 'string' ? parseInt(value) : value;
    const clamped = typeof val !== 'number' || isNaN(val) ? 100 : Math.min(Math.max(100, val), 500);
    wbConfig.config.scaleDesktop = clamped;
    origApplicationScale.value = clamped;
}

/**
 * Assigns the initial values from the Docker Compose file to the reactive refs
 * so we can display them and track when a change has been made
 */
async function assignValues() {
    compose.value = winboat.parseCompose();
    qmpPortManager.value = await PortManager.parseCompose(compose.value);

    numCores.value = Number(compose.value.services.windows.environment.CPU_CORES);
    origNumCores.value = numCores.value;


    ramGB.value = Number(compose.value.services.windows.environment.RAM_SIZE.split("G")[0]);
    origRamGB.value = ramGB.value;

    sharedFolders.value = configuredSharedFolders(compose.value.services.windows);
    origSharedFolders.value = JSON.stringify(sharedFolders.value);

    autoStartContainer.value = compose.value.services.windows.restart === RESTART_ON_FAILURE;
    origAutoStartContainer.value = autoStartContainer.value;

    heliosEnabled.value = compose.value.services.windows.image === HELIOS_IMAGE && compose.value.services.windows.environment.HELIOS === '1';
    origHeliosEnabled.value = heliosEnabled.value;
    resolution.value = heliosResolution(compose.value.services.windows);
    origResolution.value = resolution.value;
    localDisplayEnabled.value = wbConfig.config.localDisplayPreferred ?? compose.value.services.windows.environment.HELIOS_DISPLAY === 'dbus';
    origLocalDisplayEnabled.value = localDisplayEnabled.value;
    heliosSupportAvailable.value = checkHeliosSupport();

    freerdpPort.value = qmpPortManager.value.getHostPort(GUEST_RDP_PORT);
    origFreerdpPort.value = freerdpPort.value;

    origApplicationScale.value = wbConfig.config.scaleDesktop;

    const specs = await getSpecs();
    maxRamGB.value = specs.ramGB;
    maxNumCores.value = Math.max(specs.cpuCores, require('os').cpus().length);

    refreshAvailableDevices();
}

/**
 * Saves the currently specified values to the Docker Compose file
 * and then re-assigns the initial values to the reactive refs
 */
async function saveDockerCompose() {
    if (isApplyingChanges.value) return;
    isApplyingChanges.value = true;
    try {
        const previousCompose = JSON.stringify(winboat.parseCompose());
        compose.value!.services.windows.environment.RAM_SIZE = `${ramGB.value}G`;
        compose.value!.services.windows.environment.CPU_CORES = `${numCores.value}`;

        compose.value!.services.windows.restart = autoStartContainer.value ? RESTART_ON_FAILURE : RESTART_NO;

        const host = heliosEnabled.value ? await requireHelios() : undefined;
        compose.value!.services.windows = configureHelios(compose.value!.services.windows,
            heliosEnabled.value, host?.renderNode, host?.nvidia);
        if (heliosEnabled.value) compose.value!.services.windows = configureHeliosResolution(compose.value!.services.windows, resolution.value);
        const local = heliosEnabled.value && localDisplayEnabled.value;
        if (local) { autoStartContainer.value = false; compose.value!.services.windows.restart = RESTART_NO; }
        const display = await resolveHeliosDisplay(compose.value!.services.windows, local, localDisplayDirectory,
            candidate => prepareLocalDisplay({ ...compose.value!, services: { ...compose.value!.services, windows: candidate } }));
        compose.value!.services.windows = display.service;
        compose.value!.services.windows = await prepareSharedFolders(compose.value!.services.windows, sharedFolders.value);
        if (heliosEnabled.value && !origHeliosEnabled.value) {
            // The Windows driver needs Venus during its first boot. Switching
            // the host adapter must precede installing it on an existing VM.
            const { dialog, shell } = require('@electron/remote');
            const { response } = await dialog.showMessageBox({
                type: 'warning', title: 'Switch this VM to Helios',
                message: 'Back up the Windows disk first. WinBoat will restart the VM with the Helios adapter. Then copy HeliosSetup.exe from the opened folder into Windows, run it in the Browser Display console and complete its restart prompts. Graphics are not ready until that installation finishes.',
                buttons: ['Switch adapter', 'Cancel'], defaultId: 1, cancelId: 1,
            });
            if (response !== 0) { await assignValues(); return; }
            const { heliosBundlePath } = await import('../lib/helios');
            await shell.openPath(heliosBundlePath());
        }

        if (!heliosEnabled.value && origHeliosEnabled.value) {
            const port = qmpPortManager.value!.getHostPort(GUEST_API_PORT);
            const response = await fetch(`http://127.0.0.1:${port}/graphics/helios`);
            if (!response.ok || (await response.json()).installed !== false) {
                throw new Error('Uninstall Helios with HeliosSetup.exe inside Windows and restart Windows before switching back to the standard graphics adapter.');
            }
        }

        qmpPortManager.value!.setPortMapping(GUEST_RDP_PORT, freerdpPort.value);
        compose.value!.services.windows.ports = qmpPortManager.value!.composeFormat;

        wbConfig.config.localDisplayPreferred = local;
        localDisplayMessage.value = display.unavailableReason ? `Local Desktop selection saved; Browser Display is active. ${display.unavailableReason}` : '';
        if (JSON.stringify(compose.value!) !== previousCompose) await winboat.replaceCompose(compose.value!);
        await assignValues();
    } catch (error) {
        const { dialog } = require('@electron/remote');
        await dialog.showMessageBox({ type: 'error', title: 'WinBoat configuration', message: error instanceof Error ? error.message : String(error) });
    } finally {isApplyingChanges.value = false;}

}

/**
 * Adds the required fields for USB passthrough to work
 * to the Docker Compose file if they don't already exist
 */
async function addRequiredComposeFieldsUSB() {
    if (!usbPassthroughDisabled.value) {
        return;
    }
    
    isUpdatingUSBPrerequisites.value = true;
    await winboat.stopContainer();

    if(!hasUsbVolume(compose)) {
        compose.value!.services.windows.volumes.push(USB_BUS_PATH);
    }
    if(!hasQmpPort()) {
        await qmpPortManager.value!.setPortMapping(GUEST_QMP_PORT, DEFAULT_HOST_QMP_PORT);
    }

    if(!compose.value!.services.windows.environment.ARGUMENTS) {
        compose.value!.services.windows.environment.ARGUMENTS = "";
    }
    if(!hasQmpArgument(compose)) {
        compose.value!.services.windows.environment.ARGUMENTS += `\n${QMP_ARGUMENT}`;
    }

    if(!compose.value!.services.windows.environment.HOST_PORTS) {
        compose.value!.services.windows.environment.HOST_PORTS = "";
    }
    if(!hasHostPort(compose)) {
        const delimeter = compose.value!.services.windows.environment.HOST_PORTS.length == 0 ? '' : ',';
        compose.value!.services.windows.environment.HOST_PORTS += delimeter + GUEST_QMP_PORT;
    }
    
    await saveDockerCompose();

    isUpdatingUSBPrerequisites.value = false;
}

const errors = computed(() => changedResourceErrors(
    {cpu:numCores.value, ram:ramGB.value}, {cpu:origNumCores.value, ram:origRamGB.value},
    {cpu:maxNumCores.value, ram:maxRamGB.value}));

const hasUsbVolume = (_compose: typeof compose) => _compose.value?.services.windows.volumes?.includes(USB_BUS_PATH);
const hasQmpArgument = (_compose: typeof compose) => _compose.value?.services.windows.environment.ARGUMENTS?.includes(QMP_ARGUMENT);
const hasQmpPort = () => qmpPortManager.value?.hasPortMapping(GUEST_QMP_PORT) ?? false;
const hasHostPort = (_compose: typeof compose) => _compose.value?.services.windows.environment.HOST_PORTS?.includes(GUEST_QMP_PORT);

const usbPassthroughDisabled = computed(() => {
    return !hasUsbVolume(compose) || !hasQmpArgument(compose) || !hasQmpPort() || !hasHostPort(compose);
})

const saveButtonDisabled = computed(() => {
    const hasResourceChanges = 
        origNumCores.value !== numCores.value ||
        origRamGB.value !== ramGB.value ||
        (heliosEnabled.value && resolution.value !== origResolution.value) ||
        JSON.stringify(sharedFolders.value) !== origSharedFolders.value ||
        (!compose.value?.services.windows['x-winboat-shared-folders'] && sharedFolders.value.some(folder => folder.enabled)) ||
        freerdpPort.value !== origFreerdpPort.value ||
        autoStartContainer.value !== origAutoStartContainer.value ||
        heliosEnabled.value !== origHeliosEnabled.value ||
        localDisplayEnabled.value !== origLocalDisplayEnabled.value;

    const shouldBeDisabled = 
        errors.value.length || sharedFolderErrors(sharedFolders.value).length ||
        !hasResourceChanges || 
        isApplyingChanges.value;
        
    return shouldBeDisabled;
})

async function resetWinboat() {
    if (++resetQuestionCounter.value < 3) {
        return;
    }

    isResettingWinboat.value = true;
    await winboat.resetWinboat();
    app.exit();
}

// Reactivity utterly fails here, so we use this function to
// refresh via the button
function refreshAvailableDevices() {
    availableDevices.value = usbManager.devices.value.filter(device => {
        return !usbManager.isDeviceInPassthroughList(device) &&
            !USB_VID_BLACKLIST.some(x => usbManager.stringifyDevice(device).includes(x));
    });
    console.info('[Available Devices] Debug', availableDevices.value);
}

function addDevice(device: Device): void {
    try {
        usbManager.addDeviceToPassthroughList(device);
        refreshAvailableDevices();
    } catch (error) {
        console.error('Failed to add device to passthrough list:', error);
    }
}

function removeDevice(ptDevice: PTSerializableDeviceInfo): void {
    try {
        usbManager.removeDeviceFromPassthroughList(ptDevice);
        refreshAvailableDevices();
    } catch (error) {
        console.error('Failed to remove device from passthrough list:', error);
    }
}

async function toggleExperimentalFeatures() {
    wbConfig.config.experimentalFeatures = !wbConfig.config.experimentalFeatures;
    rerenderExperimental.value++;
    $emit("rerender");

    // Remove all passthrough USB devices if we're disabling experimental features
    // since USB passthrough is an experimental feature
    if (!wbConfig.config.experimentalFeatures) {
        await usbManager.removeAllPassthroughDevicesAndConfig();
    // Create the QMP interval if experimental features are enabled
    // This would get created by default since we're changing the compose and re-deploying,
    // but a scenario could also occur where the user is re-enabling experimental features
    // after the compose changes, which then would cause a bug
    // TODO: Remove after USB passthrough is no longer experimental
    } else if (winboat.containerStatus.value == ContainerStatus.Running && !winboat.hasQMPInterval) {
        console.log("Creating QMP interval because experimental features were turned on");
        winboat.createQMPInterval();
    }
}

</script>

<style scoped>
.devices-move, 
.devices-enter-active,
.devices-leave-active,
.menu-move, 
.menu-enter-active,
.menu-leave-active {
  transition: all 0.5s ease;
}

.devices-enter-from,
.devices-leave-to {
  opacity: 0;
  transform: translateX(30px);
}

.devices-leave-active,
.menu-leave-active {
  position: absolute;
}

.menu-enter-from,
.menu-leave-to {
  opacity: 0;
  transform: translateX(20px) scale(0.9);
}
</style>
