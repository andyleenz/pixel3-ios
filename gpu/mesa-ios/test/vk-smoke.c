/*
 * vk-smoke.c - Turnip (Mesa freedreno Vulkan) over bluedrm, without a Vulkan loader:
 * instance, the one physical device, a logical device, a host-visible buffer, one
 * vkCmdFillBuffer submitted with a fence, then the buffer read back.
 *
 *   vk-smoke [path to libvulkan_freedreno.dylib]   (default /usr/lib/bluevk.dylib)
 *
 * On the phone the buffer must read 0xb10e0630 everywhere ("FILL ok"). On the Mac
 * (build-turnip.sh HOST=1, the fake BlueGPU executes nothing) it stays 0 and the test
 * checks the call sequence only. Exit status 0 = every Vulkan call succeeded.
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>

/* from vk_icd.h (not in every SDK's vulkan.h) */
typedef VkResult (VKAPI_PTR *PFN_vkNegotiateLoaderICDInterfaceVersion)(uint32_t *pVersion);

#define FILL 0xb10e0630u
#define SIZE (64 * 1024)

static PFN_vkGetInstanceProcAddr gipa;
static VkInstance inst;

#define CHECK(call) do { VkResult r_ = (call); if (r_ != VK_SUCCESS) { \
	fprintf(stderr, "vk-smoke: %s -> %d\n", #call, r_); return 1; } } while (0)
#define FN(name) PFN_##name name = (PFN_##name)gipa(inst, #name)

int
main(int argc, char **argv)
{
	const char *lib = argc > 1 ? argv[1] : "/usr/lib/bluevk.dylib";
	void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
	if (!h) {
		fprintf(stderr, "vk-smoke: dlopen %s: %s\n", lib, dlerror());
		return 1;
	}
	PFN_vkNegotiateLoaderICDInterfaceVersion neg =
	    (PFN_vkNegotiateLoaderICDInterfaceVersion)dlsym(h, "vk_icdNegotiateLoaderICDInterfaceVersion");
	gipa = (PFN_vkGetInstanceProcAddr)dlsym(h, "vk_icdGetInstanceProcAddr");
	if (!neg || !gipa) {
		fprintf(stderr, "vk-smoke: no ICD entry points\n");
		return 1;
	}
	uint32_t icd = 5;
	CHECK(neg(&icd));

	PFN_vkCreateInstance vkCreateInstance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vk-smoke",
	                          .apiVersion = VK_API_VERSION_1_1 };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	CHECK(vkCreateInstance(&ici, NULL, &inst));

	FN(vkEnumeratePhysicalDevices);
	FN(vkGetPhysicalDeviceProperties);
	FN(vkGetPhysicalDeviceMemoryProperties);
	FN(vkGetDeviceProcAddr);
	FN(vkCreateDevice);
	uint32_t n = 1;
	VkPhysicalDevice pd;
	CHECK(vkEnumeratePhysicalDevices(inst, &n, &pd));
	if (n != 1) {
		fprintf(stderr, "vk-smoke: %u physical devices\n", n);
		return 1;
	}
	VkPhysicalDeviceProperties props;
	vkGetPhysicalDeviceProperties(pd, &props);
	printf("vk-smoke: device \"%s\", Vulkan %u.%u.%u, driver %#x, max image 2D %u\n", props.deviceName,
	    VK_API_VERSION_MAJOR(props.apiVersion), VK_API_VERSION_MINOR(props.apiVersion),
	    VK_API_VERSION_PATCH(props.apiVersion), props.driverVersion, props.limits.maxImageDimension2D);

	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
	                                .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
	                           .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	VkDevice dev;
	CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
#define DFN(name) PFN_##name name = (PFN_##name)vkGetDeviceProcAddr(dev, #name)
	DFN(vkGetDeviceQueue); DFN(vkCreateBuffer); DFN(vkGetBufferMemoryRequirements);
	DFN(vkAllocateMemory); DFN(vkBindBufferMemory); DFN(vkMapMemory); DFN(vkCreateCommandPool);
	DFN(vkAllocateCommandBuffers); DFN(vkBeginCommandBuffer); DFN(vkCmdFillBuffer);
	DFN(vkEndCommandBuffer); DFN(vkCreateFence); DFN(vkQueueSubmit); DFN(vkWaitForFences);
	DFN(vkDestroyDevice);

	VkQueue q;
	vkGetDeviceQueue(dev, 0, 0, &q);
	VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = SIZE,
	                           .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buf;
	CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));
	VkMemoryRequirements req;
	vkGetBufferMemoryRequirements(dev, buf, &req);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	uint32_t type = UINT32_MAX;
	VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((req.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) {
			type = i;
			break;
		}
	if (type == UINT32_MAX) {
		fprintf(stderr, "vk-smoke: no host-visible coherent memory type\n");
		return 1;
	}
	VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
	                             .allocationSize = req.size, .memoryTypeIndex = type };
	VkDeviceMemory mem;
	CHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
	CHECK(vkBindBufferMemory(dev, buf, mem, 0));
	uint32_t *p;
	CHECK(vkMapMemory(dev, mem, 0, SIZE, 0, (void **)&p));
	memset(p, 0, SIZE);

	VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0 };
	VkCommandPool pool;
	CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
	                                    .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
	                                    .commandBufferCount = 1 };
	VkCommandBuffer cb;
	CHECK(vkAllocateCommandBuffers(dev, &cai, &cb));
	VkCommandBufferBeginInfo cbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CHECK(vkBeginCommandBuffer(cb, &cbi));
	vkCmdFillBuffer(cb, buf, 0, SIZE, FILL);
	CHECK(vkEndCommandBuffer(cb));
	VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
	VkFence fence;
	CHECK(vkCreateFence(dev, &fci, NULL, &fence));
	VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
	CHECK(vkQueueSubmit(q, 1, &si, fence));
	CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, 2000000000ull));

	uint32_t good = 0;
	for (uint32_t i = 0; i < SIZE / 4; i++)
		good += p[i] == FILL;
	printf("vk-smoke: FILL %s: %u of %u words = %#x (first %#x, last %#x)\n",
	    good == SIZE / 4 ? "ok" : "NOT DONE", good, SIZE / 4, FILL, p[0], p[SIZE / 4 - 1]);
	vkDestroyDevice(dev, NULL);
	printf("vk-smoke: all calls succeeded\n");
	return 0;
}
