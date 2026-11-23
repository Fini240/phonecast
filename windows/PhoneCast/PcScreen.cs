namespace PhoneCast;
sealed class PcScreen { public PcScreen(Action<byte, byte[]> send) {} public void Start(int l, int m) {} public void Stop() {} public void ForceKeyframe() {} }
static class PcInput { public static void Handle(byte[] p) {} public static void Action(string a, Action<string> send) {} }
