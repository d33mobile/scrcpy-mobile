//
//  controller-porting.c
//  scrcpy-mobile
//
//  Created by Ethan on 2022/6/2.
//

// include time
#include <sys/time.h>

#define sc_controller_push_msg(...)     sc_controller_push_msg_hijack(__VA_ARGS__)

#include "controller.c"

#undef sc_controller_push_msg

#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define MIN(a, b) ((a) < (b) ? (a) : (b))

// Defined in screen-porting.c
#include "screen.h"
struct sc_screen *
sc_screen_current_screen(struct sc_screen *screen);

// Fix negative point values and larger than screen size
bool sc_controller_push_msg(struct sc_controller *controller,
                            struct sc_control_msg *msg) {
    if (msg->type == SC_CONTROL_MSG_TYPE_INJECT_TOUCH_EVENT) {
      	// log current touch event with time and position
        struct timeval tv;
        gettimeofday(&tv, NULL);
        // printf("inject_touch_event: %ld.%06ld, x=%d, y=%d\n", tv.tv_sec, tv.tv_usec,
        //       msg->inject_touch_event.position.point.x, msg->inject_touch_event.position.point.y);

        // x/y is negative
        msg->inject_touch_event.position.point.x = MAX(msg->inject_touch_event.position.point.x, 0);;
        msg->inject_touch_event.position.point.y = MAX(msg->inject_touch_event.position.point.y, 0);
        
        // x/y exceed max frame size
        struct sc_screen *screen = sc_screen_current_screen(NULL);
        if (screen != NULL) {
            struct sc_size screen_size;
            screen_size.width = screen->frame->width;
            screen_size.height = screen->frame->height;

			msg->inject_touch_event.position.point.x = MIN(msg->inject_touch_event.position.point.x, screen_size.width);
            msg->inject_touch_event.position.point.y = MIN(msg->inject_touch_event.position.point.y, screen_size.height);
        }
    }
    
    return sc_controller_push_msg_hijack(controller, msg);
}
