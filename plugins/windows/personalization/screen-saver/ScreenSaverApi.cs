using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Winix.ScreenSaver
{
    public static class ScreenSaverApi
    {
        private const uint SpiGetScreenSaveActive = 0x0010;
        private const uint SpiSetScreenSaveActive = 0x0011;
        private const uint SpifUpdateIniFile = 0x0001;
        private const uint SpifSendChange = 0x0002;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SystemParametersInfo(
            uint action,
            uint parameter,
            ref bool value,
            uint flags);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SystemParametersInfo(
            uint action,
            uint parameter,
            IntPtr value,
            uint flags);

        public static bool GetEnabled()
        {
            var enabled = false;
            if (!SystemParametersInfo(SpiGetScreenSaveActive, 0, ref enabled, 0))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Failed to read the screen saver state.");
            }

            return enabled;
        }

        public static void SetEnabled(bool enabled)
        {
            if (!SystemParametersInfo(
                SpiSetScreenSaveActive,
                enabled ? 1u : 0u,
                IntPtr.Zero,
                SpifUpdateIniFile | SpifSendChange))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Failed to set the screen saver state.");
            }
        }
    }
}
