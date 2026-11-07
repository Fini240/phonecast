import android.os.SystemClock;
import android.view.InputDevice;
import android.view.MotionEvent;
import java.lang.reflect.Method;

/**
 * Clears fake fingers that Android thinks are still down (InputDispatcher "pointers already down
 * for device -1"). Run via adb:  CLASSPATH=/data/local/tmp/unstick.dex app_process / Unstick [ids...]
 * Sends ACTION_CANCEL from device -1 with exactly the stuck pointer ids.
 */
public class Unstick {
    public static void main(String[] args) throws Exception {
        int[] ids = args.length > 0 ? new int[args.length] : new int[] {0, 2};
        for (int i = 0; i < args.length; i++) ids[i] = Integer.parseInt(args[i]);

        Class<?> im = Class.forName("android.hardware.input.InputManager");
        Object inputManager;
        try {
            inputManager = im.getDeclaredMethod("getInstance").invoke(null);
        } catch (NoSuchMethodException e) {
            Class<?> img = Class.forName("android.hardware.input.InputManagerGlobal");
            inputManager = img.getDeclaredMethod("getInstance").invoke(null);
        }
        Method inject = inputManager.getClass().getMethod("injectInputEvent", android.view.InputEvent.class, int.class);

        long now = SystemClock.uptimeMillis();
        int n = ids.length;
        MotionEvent.PointerProperties[] props = new MotionEvent.PointerProperties[n];
        MotionEvent.PointerCoords[] coords = new MotionEvent.PointerCoords[n];
        for (int i = 0; i < n; i++) {
            props[i] = new MotionEvent.PointerProperties();
            props[i].id = ids[i];
            props[i].toolType = MotionEvent.TOOL_TYPE_UNKNOWN;
            coords[i] = new MotionEvent.PointerCoords();
            coords[i].x = 10; coords[i].y = 10; coords[i].pressure = 1; coords[i].size = 1;
        }
        MotionEvent ev = MotionEvent.obtain(now, now, MotionEvent.ACTION_CANCEL, n, props, coords,
                0, 0, 1f, 1f, -1 /* deviceId */, 0, InputDevice.SOURCE_TOUCHSCREEN, MotionEvent.FLAG_CANCELED);
        Object ok = inject.invoke(inputManager, ev, 0 /* async */);
        System.out.println("cancel " + java.util.Arrays.toString(ids) + " injected: " + ok);
    }
}
