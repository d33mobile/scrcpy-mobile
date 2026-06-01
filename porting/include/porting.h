//
//  porting.h
//  scrcpy
//
//  Created by Ethan on 2022/6/2.
//

#ifndef porting_h
#define porting_h

#if defined(__APPLE__)
#include <OpenGLES/gltypes.h>
#include <OpenGLES/ES3/gl.h>

typedef GLfloat GLdouble;
typedef double GLclampd;

#include <SDL2/SDL_opengl_glext.h>
#else
// Android (NDK): use the NDK GLES headers (opengl.c compiles against NDK GLES).
// NB: the NDK's <GLES2/gl2ext.h> already typedefs GLdouble/GLclampd, so unlike
// the iOS path we must NOT redefine them here (would be a typedef conflict).
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#endif

// Define NDEBUG will define assert -> (void)0, see assert.h
// This will prevent to_fixed_point_16 crashed
#define NDEBUG  1

// Because conflicted function name with adb, rename it
#define adb_connect(...)    adb_connect__(__VA_ARGS__)

#endif /* porting_h */
