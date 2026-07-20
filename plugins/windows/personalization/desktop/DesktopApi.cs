using System;
using System.Runtime.InteropServices;

namespace Winix.Desktop
{
    public static class DesktopApi
    {
        private const uint SSF_HIDEICONS = 0x00004000;
        private const uint SHELLSTATE_HIDEICONS_BIT = 1u << 12;
        private const uint FWF_NOICONS = 0x00001000;
        private const int SWC_DESKTOP = 8;
        private const int SWFO_NEEDDISPATCH = 1;
        private const uint WM_SETTINGCHANGE = 0x001A;
        private const uint SMTO_ABORTIFHUNG = 0x0002;

        private static readonly Guid CLSID_ShellWindows = new Guid("9BA05972-F6A8-11CF-A442-00A0C90A8F39");
        private static readonly Guid SID_STopLevelBrowser = new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837");
        private static readonly Guid IID_IShellBrowser = new Guid("000214E2-0000-0000-C000-000000000046");
        private static readonly Guid CLSID_DesktopWallpaper = new Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD");

        public static bool GetIconsDisabled()
        {
            IFolderView2 view = GetDesktopFolderView();
            try
            {
                ThrowIfFailed(view.GetCurrentFolderFlags(out uint flags), "read desktop folder flags");
                return (flags & FWF_NOICONS) != 0;
            }
            finally
            {
                ReleaseComObject(view);
            }
        }

        public static void SetIconsDisabled(bool disabled)
        {
            IFolderView2 view = GetDesktopFolderView();
            try
            {
                ThrowIfFailed(
                    view.SetCurrentFolderFlags(FWF_NOICONS, disabled ? FWF_NOICONS : 0),
                    "set desktop folder flags");
            }
            finally
            {
                ReleaseComObject(view);
            }

            SHELLSTATE state = new SHELLSTATE();
            SHGetSetSettings(ref state, SSF_HIDEICONS, false);
            if (disabled)
                state.flags1 |= SHELLSTATE_HIDEICONS_BIT;
            else
                state.flags1 &= ~SHELLSTATE_HIDEICONS_BIT;
            SHGetSetSettings(ref state, SSF_HIDEICONS, true);

            if (SendMessageTimeout(new IntPtr(0xffff), WM_SETTINGCHANGE, UIntPtr.Zero, "ShellState", SMTO_ABORTIFHUNG, 5000, out UIntPtr messageResult) == IntPtr.Zero)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Failed to notify Windows that the Shell state changed.");

            if (GetIconsDisabled() != disabled)
                throw new InvalidOperationException("Windows did not retain the requested desktop icon visibility.");
        }

        public static string GetBackgroundColor()
        {
            IDesktopWallpaper wallpaper = CreateDesktopWallpaper();
            try
            {
                ThrowIfFailed(wallpaper.GetBackgroundColor(out uint color), "read desktop background color");
                int red = (int)(color & 0xff);
                int green = (int)((color >> 8) & 0xff);
                int blue = (int)((color >> 16) & 0xff);
                return String.Format("#{0:X2}{1:X2}{2:X2}", red, green, blue);
            }
            finally
            {
                ReleaseComObject(wallpaper);
            }
        }

        public static bool IsSolidColorActive()
        {
            IDesktopWallpaper wallpaper = CreateDesktopWallpaper();
            try
            {
                ThrowIfFailed(wallpaper.GetMonitorDevicePathCount(out uint count), "count desktop monitors");
                for (uint index = 0; index < count; index++)
                {
                    ThrowIfFailed(wallpaper.GetMonitorDevicePathAt(index, out string monitorId), "read a desktop monitor ID");
                    ThrowIfFailed(wallpaper.GetWallpaper(monitorId, out string path), "read desktop wallpaper state");
                    if (!String.IsNullOrEmpty(path))
                        return false;
                }
                return true;
            }
            finally
            {
                ReleaseComObject(wallpaper);
            }
        }

        public static void SetSolidColor(string hexColor)
        {
            if (hexColor == null || hexColor.Length != 7 || hexColor[0] != '#')
                throw new ArgumentException("The desktop color must use #RRGGBB format.", nameof(hexColor));

            int red = Convert.ToInt32(hexColor.Substring(1, 2), 16);
            int green = Convert.ToInt32(hexColor.Substring(3, 2), 16);
            int blue = Convert.ToInt32(hexColor.Substring(5, 2), 16);
            uint color = (uint)(red | (green << 8) | (blue << 16));

            IDesktopWallpaper wallpaper = CreateDesktopWallpaper();
            try
            {
                ThrowIfFailed(wallpaper.SetBackgroundColor(color), "set desktop background color");
                int result = wallpaper.Enable(false);
                if (result < 0)
                    Marshal.ThrowExceptionForHR(result);
            }
            finally
            {
                ReleaseComObject(wallpaper);
            }

            if (!String.Equals(GetBackgroundColor(), hexColor, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Windows did not retain the requested desktop background color.");
            if (!IsSolidColorActive())
                throw new InvalidOperationException("Windows did not disable the desktop wallpaper image.");
        }

        private static IDesktopWallpaper CreateDesktopWallpaper()
        {
            Type type = Type.GetTypeFromCLSID(CLSID_DesktopWallpaper, true);
            return (IDesktopWallpaper)Activator.CreateInstance(type);
        }

        private static IFolderView2 GetDesktopFolderView()
        {
            Type shellWindowsType = Type.GetTypeFromCLSID(CLSID_ShellWindows, true);
            IShellWindows shellWindows = (IShellWindows)Activator.CreateInstance(shellWindowsType);
            object dispatch = null;
            try
            {
                object location = null;
                object root = null;
                dispatch = shellWindows.FindWindowSW(ref location, ref root, SWC_DESKTOP, out int hwnd, SWFO_NEEDDISPATCH);
                if (dispatch == null)
                    throw new InvalidOperationException("Windows did not return the desktop Shell window.");

                IServiceProvider provider = (IServiceProvider)dispatch;
                Guid service = SID_STopLevelBrowser;
                Guid browserId = IID_IShellBrowser;
                ThrowIfFailed(provider.QueryService(ref service, ref browserId, out IntPtr browserPointer), "query the desktop Shell browser");
                try
                {
                    IShellBrowser browser = (IShellBrowser)Marshal.GetObjectForIUnknown(browserPointer);
                    try
                    {
                        ThrowIfFailed(browser.QueryActiveShellView(out IntPtr viewPointer), "query the active desktop Shell view");
                        try
                        {
                            return (IFolderView2)Marshal.GetObjectForIUnknown(viewPointer);
                        }
                        finally
                        {
                            Marshal.Release(viewPointer);
                        }
                    }
                    finally
                    {
                        ReleaseComObject(browser);
                    }
                }
                finally
                {
                    Marshal.Release(browserPointer);
                }
            }
            finally
            {
                ReleaseComObject(dispatch);
                ReleaseComObject(shellWindows);
            }
        }

        private static void ThrowIfFailed(int result, string operation)
        {
            if (result < 0)
                throw new COMException("Failed to " + operation + ".", result);
        }

        private static void ReleaseComObject(object value)
        {
            if (value != null && Marshal.IsComObject(value))
                Marshal.ReleaseComObject(value);
        }

        [DllImport("shell32.dll")]
        private static extern void SHGetSetSettings(ref SHELLSTATE state, uint mask, [MarshalAs(UnmanagedType.Bool)] bool set);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);

        [StructLayout(LayoutKind.Sequential)]
        private struct SHELLSTATE
        {
            public uint flags1;
            public uint dwWin95Unused;
            public uint uWin95Unused;
            public int lParamSort;
            public int iSortDirection;
            public uint version;
            public uint uNotUsed;
            public uint flags2;
        }

        [ComImport, Guid("85CB6900-4D95-11CF-960C-0080C7F4EE85"), InterfaceType(ComInterfaceType.InterfaceIsIDispatch)]
        private interface IShellWindows
        {
            [DispId(1610743808)] int Count { get; }
            [DispId(0)] object Item([In, Optional] object index);
            [DispId(-4)] object _NewEnum { get; }
            [DispId(1610743811)] int Register([MarshalAs(UnmanagedType.IDispatch)] object dispatch, int hwnd, int windowClass);
            [DispId(1610743812)] int RegisterPending(int threadId, ref object location, ref object root, int windowClass);
            [DispId(1610743813)] void Revoke(int cookie);
            [DispId(1610743814)] void OnNavigate(int cookie, ref object location);
            [DispId(1610743815)] void OnActivated(int cookie, bool active);
            [DispId(1610743816)] [return: MarshalAs(UnmanagedType.IDispatch)] object FindWindowSW(ref object location, ref object root, int windowClass, out int hwnd, int options);
            [DispId(1610743817)] void OnCreated(int cookie, [MarshalAs(UnmanagedType.IUnknown)] object unknown);
            [DispId(1610743818)] void ProcessAttachDetach(bool attach);
        }

        [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IServiceProvider
        {
            [PreserveSig] int QueryService(ref Guid service, ref Guid interfaceId, out IntPtr result);
        }

        [ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellBrowser
        {
            [PreserveSig] int GetWindow(out IntPtr hwnd);
            [PreserveSig] int ContextSensitiveHelp(bool enterMode);
            [PreserveSig] int InsertMenusSB(IntPtr sharedMenu, IntPtr menuWidths);
            [PreserveSig] int SetMenuSB(IntPtr sharedMenu, IntPtr reserved, IntPtr activeObject);
            [PreserveSig] int RemoveMenusSB(IntPtr sharedMenu);
            [PreserveSig] int SetStatusTextSB([MarshalAs(UnmanagedType.LPWStr)] string text);
            [PreserveSig] int EnableModelessSB(bool enable);
            [PreserveSig] int TranslateAcceleratorSB(IntPtr message, ushort commandId);
            [PreserveSig] int BrowseObject(IntPtr itemIdList, uint flags);
            [PreserveSig] int GetViewStateStream(uint mode, out IntPtr stream);
            [PreserveSig] int GetControlWindow(uint controlId, out IntPtr hwnd);
            [PreserveSig] int SendControlMsg(uint controlId, uint message, IntPtr wParam, IntPtr lParam, out IntPtr result);
            [PreserveSig] int QueryActiveShellView(out IntPtr shellView);
            [PreserveSig] int OnViewWindowActive(IntPtr shellView);
            [PreserveSig] int SetToolbarItems(IntPtr buttons, uint count, uint flags);
        }

        [ComImport, Guid("1AF3A467-214F-4298-908E-06B03E0B39F9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IFolderView2
        {
            [PreserveSig] int GetCurrentViewMode(out uint mode);
            [PreserveSig] int SetCurrentViewMode(uint mode);
            [PreserveSig] int GetFolder(ref Guid interfaceId, out IntPtr result);
            [PreserveSig] int Item(int index, out IntPtr itemIdList);
            [PreserveSig] int ItemCount(uint flags, out int count);
            [PreserveSig] int Items(uint flags, ref Guid interfaceId, out IntPtr result);
            [PreserveSig] int GetSelectionMarkedItem(out int index);
            [PreserveSig] int GetFocusedItem(out int index);
            [PreserveSig] int GetItemPosition(IntPtr itemIdList, out POINT point);
            [PreserveSig] int GetSpacing(out POINT point);
            [PreserveSig] int GetDefaultSpacing(out POINT point);
            [PreserveSig] int GetAutoArrange();
            [PreserveSig] int SelectItem(int index, uint flags);
            [PreserveSig] int SelectAndPositionItems(uint count, IntPtr itemIdLists, IntPtr points, uint flags);
            [PreserveSig] int SetGroupBy(IntPtr key, bool ascending);
            [PreserveSig] int GetGroupBy(IntPtr key, out bool ascending);
            [PreserveSig] int SetViewProperty(IntPtr itemIdList, IntPtr key, IntPtr value);
            [PreserveSig] int GetViewProperty(IntPtr itemIdList, IntPtr key, IntPtr value);
            [PreserveSig] int SetTileViewProperties(IntPtr itemIdList, [MarshalAs(UnmanagedType.LPWStr)] string properties);
            [PreserveSig] int SetExtendedTileViewProperties(IntPtr itemIdList, [MarshalAs(UnmanagedType.LPWStr)] string properties);
            [PreserveSig] int SetText(uint type, [MarshalAs(UnmanagedType.LPWStr)] string text);
            [PreserveSig] int SetCurrentFolderFlags(uint mask, uint flags);
            [PreserveSig] int GetCurrentFolderFlags(out uint flags);
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT
        {
            public int x;
            public int y;
        }

        [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IDesktopWallpaper
        {
            [PreserveSig] int SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorId, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
            [PreserveSig] int GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorId, [MarshalAs(UnmanagedType.LPWStr)] out string wallpaper);
            [PreserveSig] int GetMonitorDevicePathAt(uint monitorIndex, [MarshalAs(UnmanagedType.LPWStr)] out string monitorId);
            [PreserveSig] int GetMonitorDevicePathCount(out uint count);
            [PreserveSig] int GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorId, IntPtr rectangle);
            [PreserveSig] int SetBackgroundColor(uint color);
            [PreserveSig] int GetBackgroundColor(out uint color);
            [PreserveSig] int SetPosition(uint position);
            [PreserveSig] int GetPosition(out uint position);
            [PreserveSig] int SetSlideshow(IntPtr items);
            [PreserveSig] int GetSlideshow(out IntPtr items);
            [PreserveSig] int SetSlideshowOptions(uint options, uint slideshowTick);
            [PreserveSig] int GetSlideshowOptions(out uint options, out uint slideshowTick);
            [PreserveSig] int AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitorId, uint direction);
            [PreserveSig] int GetStatus(out uint state);
            [PreserveSig] int Enable(bool enable);
        }
    }
}
