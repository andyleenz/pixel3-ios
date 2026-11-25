/*
 * WebGLHello.app - a WKWebView page drawing a spinning triangle with WebGL (WebKit's GPU process, ANGLE on
 * Metal). After 120 animation frames the page reads back pixels, reports the renderer and frame rate to the app,
 * and the app writes Documents/hello.txt, which tools/bluerun apptest waits for.
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

static NSString *const kPage = @"<!doctype html><meta name=viewport content='width=device-width'>"
"<body style='margin:0;background:#123'><canvas id=c style='width:100vw;height:100vh'></canvas><script>"
"const post=m=>webkit.messageHandlers.hello.postMessage(m);"
"window.onerror=(e,u,l)=>post('webglhello: error '+e+' line '+l);"
"let n=0,t0=0;function run(){"
"const c=document.getElementById('c');c.width=innerWidth*devicePixelRatio;c.height=innerHeight*devicePixelRatio;"
"const gl=c.getContext('webgl',{preserveDrawingBuffer:true});"
"if(!gl){post('webglhello: no WebGL context');return;}"
"const dbg=gl.getExtension('WEBGL_debug_renderer_info');"
"const who=dbg?gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL):gl.getParameter(gl.RENDERER);"
"const sh=(t,s)=>{const o=gl.createShader(t);gl.shaderSource(o,s);gl.compileShader(o);return o};"
"const p=gl.createProgram();"
"gl.attachShader(p,sh(gl.VERTEX_SHADER,'attribute vec2 a;uniform float t;varying vec3 v;void main(){float s=sin(t),k=cos(t);"
"gl_Position=vec4(a.x*k-a.y*s,a.x*s+a.y*k,0,1);v=vec3(a*.5+.5,.6);}'));"
"gl.attachShader(p,sh(gl.FRAGMENT_SHADER,'precision mediump float;varying vec3 v;void main(){gl_FragColor=vec4(v,1);}'));"
"gl.linkProgram(p);gl.useProgram(p);"
"const b=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,b);"
"gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([0,.8,-.7,-.5,.7,-.5]),gl.STATIC_DRAW);"
"gl.enableVertexAttribArray(0);gl.vertexAttribPointer(0,2,gl.FLOAT,false,0,0);"
"const ut=gl.getUniformLocation(p,'t');"
"function f(ts){if(!n)t0=ts;n++;gl.viewport(0,0,c.width,c.height);gl.clearColor(.07,.13,.2,1);gl.clear(gl.COLOR_BUFFER_BIT);"
"gl.uniform1f(ut,ts/600);gl.drawArrays(gl.TRIANGLES,0,3);"
"if(n==121){const px=new Uint8Array(4);gl.readPixels(c.width>>1,c.height>>1,1,1,gl.RGBA,gl.UNSIGNED_BYTE,px);"
"const bg=new Uint8Array(4);gl.readPixels(2,2,1,1,gl.RGBA,gl.UNSIGNED_BYTE,bg);"
"post('webglhello: renderer '+who+', 120 frames in '+((ts-t0)/1000).toFixed(2)+' s ('+(120000/(ts-t0)).toFixed(1)+' fps), centre '+px.join(',')+', corner '+bg.join(',')+', gl error '+gl.getError());}"
"requestAnimationFrame(f);}requestAnimationFrame(f);}"
"try{run();}catch(e){post('webglhello: exception '+e+' '+(e.stack||''));}"
"</script>";

@interface Hello : UIResponder <UIApplicationDelegate, WKScriptMessageHandler>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation Hello
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)msg
{
	NSString *line = [NSString stringWithFormat:@"%@\n", msg.body];
	NSLog(@"BLUELINE WEBGLHELLO: %@", line);
	NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
	[[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
	[line writeToFile:[docs stringByAppendingPathComponent:@"hello.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options
{
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
	[cfg.userContentController addScriptMessageHandler:self name:@"hello"];
	WKWebView *web = [[WKWebView alloc] initWithFrame:self.window.bounds configuration:cfg];
	UIViewController *vc = [UIViewController new];
	vc.view = web;
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];
	[web loadHTMLString:kPage baseURL:[NSURL URLWithString:@"https://webglhello.local/"]];
	return YES;
}
@end

int
main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([Hello class]));
	}
}
