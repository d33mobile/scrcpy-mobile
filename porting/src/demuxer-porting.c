//
//  demuxer-porting.c
//  scrcpy-module
//
//  Created by Ethan on 2023/5/20.
//

#define avcodec_alloc_context3(...)     avcodec_alloc_context3_hijack(__VA_ARGS__)

#include "demuxer.c"

#undef avcodec_alloc_context3

int ScrcpyEnableHardwareDecoding(void);

AVCodecContext *avcodec_alloc_context3(const AVCodec *codec);
AVCodecContext *avcodec_alloc_context3_hijack(const AVCodec *codec) {
    AVCodecContext *context = avcodec_alloc_context3(codec);

#if defined(__APPLE__)
    if (context->codec_type != AVMEDIA_TYPE_VIDEO ||
        ScrcpyEnableHardwareDecoding() == 0) {
        printf("hardware decoding is disabled, codec_type=%d(video=%d|audio=%d), ScrcpyEnableHardwareDecoding=%d\n",
               context->codec_type, AVMEDIA_TYPE_VIDEO, AVMEDIA_TYPE_AUDIO, ScrcpyEnableHardwareDecoding());
        return context;
    }

    // Create context with hardware decoder (iOS VideoToolbox)
    context->hw_device_ctx = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_VIDEOTOOLBOX);
    if (!context->hw_device_ctx) {
        avcodec_free_context(&context);
        return NULL;
    }

    if (av_hwdevice_ctx_init(context->hw_device_ctx) < 0) {
        av_buffer_unref(&context->hw_device_ctx);
        avcodec_free_context(&context);
        return NULL;
    }

    return context;
#else
    // Android (NDK): always software-decode. No VideoToolbox/Metal; scrcpy's
    // normal FFmpeg SW decode + SDL_UpdateYUVTexture path runs.
    return context;
#endif
}
