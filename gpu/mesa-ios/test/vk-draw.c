/*
 * vk-draw.c - draw one QuartzCore pipeline, translated by metal2vulkan, through a Vulkan ICD
 * without a loader (Turnip on the phone, MoltenVK on the Mac for a reference picture).
 *
 *   vk-draw ICD.dylib VERT.spv FRAG.spv [out.ppm]
 *
 * The pipeline is QuartzCore's stroke_line_vert_lpf + stroke_line_frag_lpf (iOS 16.7), made by
 * gpu/metal/qc-spv.sh. It strokes the segments of a polyline, one instance per segment and a
 * 4-vertex strip each, with antialiased edges. Its interface (metal2vulkan --emit-meta): no
 * descriptor sets, 64 bytes of vertex push constants holding Metal buffer slots as addresses:
 *
 *   0   slot 0 guest base   points, float2 per point (segment i = points i and i+1)
 *   8   slot 1 guest base   transform: x' = x * [0].x + [3].x, y' = y * [1].y + [3].y (float4 x4)
 *   16  slot 2 guest base   style: color (float4, premultiplied), half width, half cap length
 *   24  zero address        where out-of-bounds loads read (a zeroed buffer)
 *   56  slot 0 bounds       bytes before the bind offset, buffer length
 *
 * A guest base is the buffer's device address less 2^31 (metal2vulkan's identity domains).
 * The target is 256x256 B8G8R8A8_UNORM, cleared to black; the test strokes a square and a
 * diagonal in orange (premultiplied 1, 0.5, 0, 1) with a half width of 4 px and checks pixels.
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>

typedef VkResult (VKAPI_PTR *PFN_vkNegotiateLoaderICDInterfaceVersion)(uint32_t *pVersion);

#define W 256
#define H 256

static PFN_vkGetInstanceProcAddr gipa;
static VkInstance inst;
static VkDevice dev;
static PFN_vkGetDeviceProcAddr gdpa;

#define CHECK(call) do { VkResult r_ = (call); if (r_ != VK_SUCCESS) { \
	fprintf(stderr, "vk-draw: %s -> %d\n", #call, r_); return 1; } } while (0)
#define FN(name) PFN_##name name = (PFN_##name)gipa(inst, #name)
#define DFN(name) PFN_##name name = (PFN_##name)gdpa(dev, #name)

static uint32_t *
load(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	*len = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint32_t *p = malloc(*len);
	if (fread(p, 1, *len, f) != *len) {
		free(p);
		p = NULL;
	}
	fclose(f);
	return p;
}

static VkPhysicalDeviceMemoryProperties memprops;

static int
memtype(uint32_t bits, VkMemoryPropertyFlags want)
{
	for (uint32_t i = 0; i < memprops.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (memprops.memoryTypes[i].propertyFlags & want) == want)
			return i;
	return -1;
}

struct buf {
	VkBuffer b;
	VkDeviceMemory m;
	void *p;
	VkDeviceAddress a;
};

static int
mkbuf(struct buf *o, VkDeviceSize size, VkBufferUsageFlags usage)
{
	DFN(vkCreateBuffer); DFN(vkGetBufferMemoryRequirements); DFN(vkAllocateMemory);
	DFN(vkBindBufferMemory); DFN(vkMapMemory); DFN(vkGetBufferDeviceAddress);
	VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
	                           .usage = usage | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT };
	CHECK(vkCreateBuffer(dev, &bci, NULL, &o->b));
	VkMemoryRequirements req;
	vkGetBufferMemoryRequirements(dev, o->b, &req);
	int t = memtype(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	if (t < 0) {
		fprintf(stderr, "vk-draw: no host-visible coherent memory\n");
		return 1;
	}
	VkMemoryAllocateFlagsInfo fl = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO,
	                                 .flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT };
	VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = &fl,
	                             .allocationSize = req.size, .memoryTypeIndex = t };
	CHECK(vkAllocateMemory(dev, &mai, NULL, &o->m));
	CHECK(vkBindBufferMemory(dev, o->b, o->m, 0));
	CHECK(vkMapMemory(dev, o->m, 0, size, 0, &o->p));
	memset(o->p, 0, size);
	VkBufferDeviceAddressInfo ai = { .sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, .buffer = o->b };
	o->a = vkGetBufferDeviceAddress(dev, &ai);
	return 0;
}

static VkShaderModule
module(const char *path)
{
	DFN(vkCreateShaderModule);
	size_t len;
	uint32_t *code = load(path, &len);
	if (!code) {
		fprintf(stderr, "vk-draw: cannot read %s\n", path);
		return VK_NULL_HANDLE;
	}
	VkShaderModuleCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
	                                .codeSize = len, .pCode = code };
	VkShaderModule m = VK_NULL_HANDLE;
	VkResult r = vkCreateShaderModule(dev, &ci, NULL, &m);
	free(code);
	if (r != VK_SUCCESS)
		fprintf(stderr, "vk-draw: vkCreateShaderModule %s -> %d\n", path, r);
	return m;
}

/* pixel (x, y) of the B8G8R8A8 picture as 0xAARRGGBB */
static const uint8_t *pix;
static uint32_t
px(int x, int y)
{
	const uint8_t *q = pix + (y * W + x) * 4;
	return (uint32_t)q[3] << 24 | (uint32_t)q[2] << 16 | (uint32_t)q[1] << 8 | q[0];
}

int
main(int argc, char **argv)
{
	if (argc < 4) {
		fprintf(stderr, "usage: vk-draw ICD.dylib VERT.spv FRAG.spv [out.ppm]\n");
		return 2;
	}
	void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!h) {
		fprintf(stderr, "vk-draw: dlopen %s: %s\n", argv[1], dlerror());
		return 1;
	}
	PFN_vkNegotiateLoaderICDInterfaceVersion neg =
	    (PFN_vkNegotiateLoaderICDInterfaceVersion)dlsym(h, "vk_icdNegotiateLoaderICDInterfaceVersion");
	gipa = (PFN_vkGetInstanceProcAddr)dlsym(h, "vk_icdGetInstanceProcAddr");
	if (!gipa) {
		fprintf(stderr, "vk-draw: no ICD entry points\n");
		return 1;
	}
	if (neg) {
		uint32_t icd = 5;
		CHECK(neg(&icd));
	}

	PFN_vkCreateInstance vkCreateInstance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vk-draw",
	                          .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	CHECK(vkCreateInstance(&ici, NULL, &inst));

	FN(vkEnumeratePhysicalDevices); FN(vkGetPhysicalDeviceProperties);
	FN(vkGetPhysicalDeviceMemoryProperties); FN(vkCreateDevice);
	gdpa = (PFN_vkGetDeviceProcAddr)gipa(inst, "vkGetDeviceProcAddr");
	uint32_t n = 1;
	VkPhysicalDevice pd;
	VkResult er = vkEnumeratePhysicalDevices(inst, &n, &pd);
	if ((er != VK_SUCCESS && er != VK_INCOMPLETE) || n < 1) {
		fprintf(stderr, "vk-draw: no physical device (%d)\n", er);
		return 1;
	}
	VkPhysicalDeviceProperties props;
	vkGetPhysicalDeviceProperties(pd, &props);
	vkGetPhysicalDeviceMemoryProperties(pd, &memprops);
	printf("vk-draw: device \"%s\", Vulkan %u.%u.%u\n", props.deviceName, VK_API_VERSION_MAJOR(props.apiVersion),
	    VK_API_VERSION_MINOR(props.apiVersion), VK_API_VERSION_PATCH(props.apiVersion));

	VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
	                                         .dynamicRendering = VK_TRUE };
	VkPhysicalDeviceVulkan12Features f12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
	                                         .pNext = &f13, .bufferDeviceAddress = VK_TRUE };
	VkPhysicalDeviceExtendedDynamicStateFeaturesEXT eds = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT, .pNext = &f12,
		.extendedDynamicState = VK_TRUE };
	VkPhysicalDeviceExtendedDynamicState2FeaturesEXT eds2 = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_2_FEATURES_EXT, .pNext = &eds,
		.extendedDynamicState2 = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &eds2,
	                                 .features = { .shaderInt64 = VK_TRUE } };
	const char *dext[] = { "VK_EXT_extended_dynamic_state", "VK_EXT_extended_dynamic_state2",
	                       "VK_KHR_portability_subset" };
	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
	                                .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f2,
	                           .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
	                           .enabledExtensionCount = getenv("VK_DRAW_PORTABILITY") ? 3 : 2,
	                           .ppEnabledExtensionNames = dext };
	CHECK(vkCreateDevice(pd, &dci, NULL, &dev));

	DFN(vkGetDeviceQueue); DFN(vkCreateImage); DFN(vkGetImageMemoryRequirements); DFN(vkAllocateMemory);
	DFN(vkBindImageMemory); DFN(vkCreateImageView); DFN(vkCreatePipelineLayout);
	DFN(vkCreateGraphicsPipelines); DFN(vkCreateCommandPool); DFN(vkAllocateCommandBuffers);
	DFN(vkBeginCommandBuffer); DFN(vkEndCommandBuffer); DFN(vkCmdPipelineBarrier);
	DFN(vkCmdBeginRendering); DFN(vkCmdEndRendering); DFN(vkCmdBindPipeline); DFN(vkCmdPushConstants);
	DFN(vkCmdSetViewport); DFN(vkCmdSetScissor); DFN(vkCmdSetDepthBias); DFN(vkCmdSetBlendConstants);
	DFN(vkCmdSetStencilCompareMask); DFN(vkCmdSetStencilWriteMask); DFN(vkCmdSetStencilReference);
	DFN(vkCmdSetCullMode); DFN(vkCmdSetFrontFace); DFN(vkCmdSetPrimitiveTopology);
	DFN(vkCmdSetDepthTestEnable); DFN(vkCmdSetDepthWriteEnable); DFN(vkCmdSetDepthCompareOp);
	DFN(vkCmdSetStencilTestEnable); DFN(vkCmdSetStencilOp); DFN(vkCmdSetPrimitiveRestartEnable);
	DFN(vkCmdDraw); DFN(vkCmdCopyImageToBuffer); DFN(vkCreateFence); DFN(vkQueueSubmit);
	DFN(vkWaitForFences); DFN(vkDestroyDevice);

	/* the render target */
	VkImageCreateInfo imci = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
	                           .format = VK_FORMAT_B8G8R8A8_UNORM, .extent = { W, H, 1 }, .mipLevels = 1,
	                           .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
	                           .tiling = VK_IMAGE_TILING_OPTIMAL,
	                           .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT };
	VkImage img;
	CHECK(vkCreateImage(dev, &imci, NULL, &img));
	VkMemoryRequirements ireq;
	vkGetImageMemoryRequirements(dev, img, &ireq);
	VkMemoryAllocateInfo imai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = ireq.size,
	                              .memoryTypeIndex = memtype(ireq.memoryTypeBits, 0) };
	VkDeviceMemory imem;
	CHECK(vkAllocateMemory(dev, &imai, NULL, &imem));
	CHECK(vkBindImageMemory(dev, img, imem, 0));
	VkImageViewCreateInfo ivci = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img,
	                               .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_B8G8R8A8_UNORM,
	                               .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView view;
	CHECK(vkCreateImageView(dev, &ivci, NULL, &view));

	/* the Metal buffers */
	static const float points[][2] = { { 48, 48 }, { 208, 48 }, { 208, 208 }, { 48, 208 }, { 48, 48 }, { 208, 208 } };
	const uint32_t nseg = sizeof(points) / sizeof(points[0]) - 1;
	struct buf pts, xf, style, zero, rb;
	if (mkbuf(&pts, sizeof(points), 0) || mkbuf(&xf, 64, 0) || mkbuf(&style, 32, 0) || mkbuf(&zero, 256, 0) ||
	    mkbuf(&rb, W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT))
		return 1;
	memcpy(pts.p, points, sizeof(points));
	float *m = xf.p; /* pixels to clip space */
	m[0] = 2.0f / W;
	m[5] = 2.0f / H;
	m[12] = -1.0f;
	m[13] = -1.0f;
	float *st = style.p;
	st[0] = 1.0f; st[1] = 0.5f; st[2] = 0.0f; st[3] = 1.0f; /* premultiplied orange */
	st[4] = 4.0f;                                           /* half width */
	st[5] = 4.0f;                                           /* half cap length */
	const uint64_t bias = 1ull << 31;
	uint64_t push[8] = { 0 };
	push[0] = pts.a - bias;
	push[1] = xf.a - bias;
	push[2] = style.a - bias;
	push[3] = zero.a;
	push[7] = (uint64_t)sizeof(points) << 32; /* bounds: 0 before, length */
	printf("vk-draw: buffers at %#llx %#llx %#llx, zero %#llx\n", (unsigned long long)pts.a,
	    (unsigned long long)xf.a, (unsigned long long)style.a, (unsigned long long)zero.a);

	/* the pipeline */
	VkShaderModule vs = module(argv[2]), fs = module(argv[3]);
	if (!vs || !fs)
		return 1;
	VkPushConstantRange pcr = { VK_SHADER_STAGE_VERTEX_BIT, 0, 64 };
	VkPipelineLayoutCreateInfo plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
	                                    .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr };
	VkPipelineLayout layout;
	CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkPipelineShaderStageCreateInfo stages[2] = {
		{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
		  .module = vs, .pName = "main" },
		{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
		  .module = fs, .pName = "main" },
	};
	VkPipelineVertexInputStateCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ia = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
	                                              .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP };
	VkPipelineViewportStateCreateInfo vp = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
	                                         .viewportCount = 1, .scissorCount = 1 };
	VkPipelineRasterizationStateCreateInfo rs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
	                                              .polygonMode = VK_POLYGON_MODE_FILL, .lineWidth = 1.0f };
	VkPipelineMultisampleStateCreateInfo ms = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
	                                            .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineDepthStencilStateCreateInfo ds = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO };
	VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cb = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
	                                           .attachmentCount = 1, .pAttachments = &cba };
	/* the dynamic states metal2vulkan's meta lists for the pipeline */
	VkDynamicState dyn[] = {
		VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR, VK_DYNAMIC_STATE_DEPTH_BIAS,
		VK_DYNAMIC_STATE_BLEND_CONSTANTS, VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK,
		VK_DYNAMIC_STATE_STENCIL_WRITE_MASK, VK_DYNAMIC_STATE_STENCIL_REFERENCE,
		VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY, VK_DYNAMIC_STATE_PRIMITIVE_RESTART_ENABLE,
		VK_DYNAMIC_STATE_CULL_MODE, VK_DYNAMIC_STATE_FRONT_FACE, VK_DYNAMIC_STATE_DEPTH_TEST_ENABLE,
		VK_DYNAMIC_STATE_DEPTH_WRITE_ENABLE, VK_DYNAMIC_STATE_DEPTH_COMPARE_OP,
		VK_DYNAMIC_STATE_STENCIL_TEST_ENABLE, VK_DYNAMIC_STATE_STENCIL_OP,
	};
	VkPipelineDynamicStateCreateInfo dy = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
	                                        .dynamicStateCount = sizeof(dyn) / sizeof(dyn[0]), .pDynamicStates = &dyn[0] };
	VkFormat cfmt = VK_FORMAT_B8G8R8A8_UNORM;
	VkPipelineRenderingCreateInfo prci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
	                                       .colorAttachmentCount = 1, .pColorAttachmentFormats = &cfmt };
	VkGraphicsPipelineCreateInfo gpci = { .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &prci,
	                                      .stageCount = 2, .pStages = stages, .pVertexInputState = &vi,
	                                      .pInputAssemblyState = &ia, .pViewportState = &vp,
	                                      .pRasterizationState = &rs, .pMultisampleState = &ms,
	                                      .pDepthStencilState = &ds, .pColorBlendState = &cb,
	                                      .pDynamicState = &dy, .layout = layout };
	VkPipeline pipe;
	CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpci, NULL, &pipe));
	printf("vk-draw: pipeline stroke_line_vert_lpf + stroke_line_frag_lpf created\n");

	/* record */
	VkQueue q;
	vkGetDeviceQueue(dev, 0, 0, &q);
	VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0 };
	VkCommandPool pool;
	CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
	                                    .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer c;
	CHECK(vkAllocateCommandBuffers(dev, &cai, &c));
	VkCommandBufferBeginInfo cbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CHECK(vkBeginCommandBuffer(c, &cbi));

	VkImageMemoryBarrier toatt = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
	                               .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
	                               .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
	                               .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
	                               .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	                               .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = img,
	                               .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0,
	    0, NULL, 0, NULL, 1, &toatt);
	VkRenderingAttachmentInfo att = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
	                                  .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
	                                  .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
	                                  .clearValue = { .color = { { 0, 0, 0, 1 } } } };
	VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { W, H } },
	                       .layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &att };
	vkCmdBeginRendering(c, &ri);
	vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
	VkViewport vpt = { 0, 0, W, H, 0, 1 };
	VkRect2D sc = { { 0, 0 }, { W, H } };
	vkCmdSetViewport(c, 0, 1, &vpt);
	vkCmdSetScissor(c, 0, 1, &sc);
	vkCmdSetDepthBias(c, 0, 0, 0);
	float bc[4] = { 0 };
	vkCmdSetBlendConstants(c, bc);
	vkCmdSetStencilCompareMask(c, VK_STENCIL_FACE_FRONT_AND_BACK, 0xff);
	vkCmdSetStencilWriteMask(c, VK_STENCIL_FACE_FRONT_AND_BACK, 0xff);
	vkCmdSetStencilReference(c, VK_STENCIL_FACE_FRONT_AND_BACK, 0);
	vkCmdSetPrimitiveTopology(c, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP);
	vkCmdSetPrimitiveRestartEnable(c, VK_FALSE);
	vkCmdSetCullMode(c, VK_CULL_MODE_NONE);
	vkCmdSetFrontFace(c, VK_FRONT_FACE_COUNTER_CLOCKWISE);
	vkCmdSetDepthTestEnable(c, VK_FALSE);
	vkCmdSetDepthWriteEnable(c, VK_FALSE);
	vkCmdSetDepthCompareOp(c, VK_COMPARE_OP_ALWAYS);
	vkCmdSetStencilTestEnable(c, VK_FALSE);
	vkCmdSetStencilOp(c, VK_STENCIL_FACE_FRONT_AND_BACK, VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP,
	    VK_STENCIL_OP_KEEP, VK_COMPARE_OP_ALWAYS);
	vkCmdPushConstants(c, layout, VK_SHADER_STAGE_VERTEX_BIT, 0, 64, push);
	vkCmdDraw(c, 4, nseg, 0, 0);
	vkCmdEndRendering(c);

	VkImageMemoryBarrier tosrc = toatt;
	tosrc.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
	tosrc.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
	tosrc.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
	tosrc.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
	vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0,
	    NULL, 0, NULL, 1, &tosrc);
	VkBufferImageCopy bic = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { W, H, 1 } };
	vkCmdCopyImageToBuffer(c, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rb.b, 1, &bic);
	VkMemoryBarrier tohost = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
	                           .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &tohost, 0, NULL, 0,
	    NULL);
	CHECK(vkEndCommandBuffer(c));

	VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
	VkFence fence;
	CHECK(vkCreateFence(dev, &fci, NULL, &fence));
	VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &c };
	CHECK(vkQueueSubmit(q, 1, &si, fence));
	CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, 5000000000ull));

	/* check */
	pix = rb.p;
	uint32_t lit = 0, full = 0;
	uint64_t sum = 0;
	for (int i = 0; i < W * H; i++) {
		uint32_t v = ((const uint32_t *)pix)[i];
		sum = sum * 31 + v;
		lit += (v & 0x00ffffff) != 0;
		full += v == 0xffff8000u;
	}
	struct { int x, y; uint32_t want; const char *what; } probes[] = {
		{ 128, 48, 0xffff8000u, "top edge, centre of the stroke" },
		{ 208, 128, 0xffff8000u, "right edge" },
		{ 128, 128, 0xffff8000u, "diagonal, centre" },
		{ 128, 60, 0xff000000u, "inside the square, off the strokes" },
		{ 10, 10, 0xff000000u, "outside" },
	};
	int bad = 0;
	for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
		/* the stroke's centre line lies on a pixel edge; take the brighter of the two sides */
		uint32_t v = px(probes[i].x, probes[i].y), v2 = px(probes[i].x - (probes[i].x == 208), probes[i].y - (probes[i].y == 48));
		int ok = v == probes[i].want || v2 == probes[i].want;
		bad += !ok;
		printf("vk-draw: (%3d,%3d) %08x %s  %s\n", probes[i].x, probes[i].y, v, ok ? "ok " : "BAD", probes[i].what);
	}
	printf("vk-draw: %u lit pixels, %u full orange, hash %016llx\n", lit, full, (unsigned long long)sum);

	if (argc > 4) {
		FILE *f = fopen(argv[4], "wb");
		if (f) {
			fprintf(f, "P6\n%d %d\n255\n", W, H);
			for (int i = 0; i < W * H; i++) {
				const uint8_t *q = pix + i * 4;
				fputc(q[2], f); fputc(q[1], f); fputc(q[0], f);
			}
			fclose(f);
			printf("vk-draw: wrote %s\n", argv[4]);
		}
	}
	vkDestroyDevice(dev, NULL);
	printf("vk-draw: %s\n", bad ? "DRAW WRONG" : "DRAW ok");
	return bad ? 3 : 0;
}
