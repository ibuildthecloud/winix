using System;
using System.IO;
using System.Runtime.InteropServices;

namespace Winix.Windows.Personalization
{
    // Windows 11's current taskbar settings are implemented by an internal
    // SystemSettings.DataModel.ISettingItem handler. This wrapper intentionally
    // exposes only the settings whose live ABI is verified below. Taskbar
    // autohide uses the documented shell appbar API instead.
    public static class TaskbarSettingsApi
    {
        private const string HandlerDll = "SettingsHandlers_DesktopTaskbar.dll";
        private const string ValueProperty = "Value";

        private static readonly Guid SettingItemIid =
            new Guid("40c037cc-d8bf-489e-8697-d66baa3221bf");
        private static readonly Guid PropertyValueIid =
            new Guid("4bd682dd-7554-40e9-9a9b-82654ede7e62");
        private static readonly Guid PropertyValueStaticsIid =
            new Guid("629bdbc8-d932-4ff4-96b9-8d96c5c1e858");

        private const int PropertyTypeInt32 = 4;
        private const int PropertyTypeBoolean = 11;

        private const uint AbmGetState = 0x00000004;
        private const uint AbmSetState = 0x0000000A;
        private const uint AbsAutohide = 0x00000001;
        private const uint AbsAlwaysOnTop = 0x00000002;

        [StructLayout(LayoutKind.Sequential)]
        private struct AppBarData
        {
            public uint cbSize;
            public IntPtr hWnd;
            public uint uCallbackMessage;
            public uint uEdge;
            public Rect rc;
            public IntPtr lParam;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Rect
        {
            public int left;
            public int top;
            public int right;
            public int bottom;
        }

        [DllImport("shell32.dll")]
        private static extern UIntPtr SHAppBarMessage(uint message, ref AppBarData data);

        [DllImport("shell32.dll")]
        private static extern int SHGetKnownFolderPath(
            in Guid folderId,
            uint flags,
            IntPtr token,
            out IntPtr path);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string className, string windowName);

        [DllImport("combase.dll", CharSet = CharSet.Unicode)]
        private static extern int WindowsCreateString(
            string sourceString,
            uint length,
            out IntPtr hstring);

        [DllImport("combase.dll")]
        private static extern int WindowsDeleteString(IntPtr hstring);

        [DllImport("combase.dll")]
        private static extern int RoGetActivationFactory(
            IntPtr activatableClassId,
            in Guid iid,
            out IntPtr factory);

        [DllImport(HandlerDll, EntryPoint = "GetSetting")]
        private static extern int GetSetting(IntPtr settingId, out IntPtr setting);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int QueryInterfaceDelegate(
            IntPtr self,
            in Guid iid,
            out IntPtr result);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate uint ReleaseDelegate(IntPtr self);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetValueDelegate(
            IntPtr self,
            IntPtr propertyName,
            out IntPtr value);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int SetValueDelegate(
            IntPtr self,
            IntPtr propertyName,
            IntPtr value);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetInt32Delegate(IntPtr self, out int value);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetBooleanDelegate(IntPtr self, out byte value);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int CreateInt32Delegate(IntPtr self, int value, out IntPtr result);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int CreateBooleanDelegate(IntPtr self, byte value, out IntPtr result);

        public static int ReadInt32(string settingId)
        {
            return ReadValue(settingId, PropertyTypeInt32, propertyValue =>
            {
                int value;
                ThrowIfFailed(GetDelegate<GetInt32Delegate>(propertyValue, 11)(propertyValue, out value));
                return value;
            });
        }

        public static bool ReadBoolean(string settingId)
        {
            return ReadValue(settingId, PropertyTypeBoolean, propertyValue =>
            {
                byte value;
                ThrowIfFailed(GetDelegate<GetBooleanDelegate>(propertyValue, 18)(propertyValue, out value));
                return value != 0;
            });
        }

        public static bool ReadAutomaticallyHide()
        {
            AppBarData data = CreateTaskbarAppBarData();
            ulong state = SHAppBarMessage(AbmGetState, ref data).ToUInt64();
            return (state & AbsAutohide) != 0;
        }

        public static void WriteAutomaticallyHide(bool value)
        {
            AppBarData data = CreateTaskbarAppBarData();
            data.lParam = value ? new IntPtr(AbsAutohide) : new IntPtr(AbsAlwaysOnTop);
            SHAppBarMessage(AbmSetState, ref data);
        }

        public static string ExpandKnownFolderPath(string value)
        {
            if (string.IsNullOrEmpty(value) || value[0] != '{')
            {
                return value;
            }
            int closingBrace = value.IndexOf('}');
            if (closingBrace < 0 || !Guid.TryParse(value.Substring(0, closingBrace + 1), out Guid folderId))
            {
                return value;
            }
            IntPtr path = IntPtr.Zero;
            try
            {
                int result = SHGetKnownFolderPath(in folderId, 0, IntPtr.Zero, out path);
                if (result < 0 || path == IntPtr.Zero)
                {
                    return value;
                }
                string folder = Marshal.PtrToStringUni(path);
                string relative = value.Substring(closingBrace + 1).TrimStart('\\', '/');
                return string.IsNullOrEmpty(relative) ? folder : Path.Combine(folder, relative);
            }
            finally
            {
                if (path != IntPtr.Zero)
                {
                    Marshal.FreeCoTaskMem(path);
                }
            }
        }

        public static void WriteInt32(string settingId, int value)
        {
            IntPtr boxed = IntPtr.Zero;
            IntPtr factory = IntPtr.Zero;
            IntPtr className = IntPtr.Zero;
            try
            {
                className = CreateHString("Windows.Foundation.PropertyValue");
                ThrowIfFailed(RoGetActivationFactory(className, in PropertyValueStaticsIid, out factory));
                ThrowIfFailed(GetDelegate<CreateInt32Delegate>(factory, 10)(factory, value, out boxed));
                WriteValue(settingId, boxed);
            }
            finally
            {
                Release(boxed);
                Release(factory);
                DeleteHString(className);
            }
        }

        public static void WriteBoolean(string settingId, bool value)
        {
            IntPtr boxed = IntPtr.Zero;
            IntPtr factory = IntPtr.Zero;
            IntPtr className = IntPtr.Zero;
            try
            {
                className = CreateHString("Windows.Foundation.PropertyValue");
                ThrowIfFailed(RoGetActivationFactory(className, in PropertyValueStaticsIid, out factory));
                ThrowIfFailed(GetDelegate<CreateBooleanDelegate>(factory, 17)(factory, value ? (byte)1 : (byte)0, out boxed));
                WriteValue(settingId, boxed);
            }
            finally
            {
                Release(boxed);
                Release(factory);
                DeleteHString(className);
            }
        }

        private static T ReadValue<T>(string settingId, int expectedType, Func<IntPtr, T> read)
        {
            IntPtr value = IntPtr.Zero;
            IntPtr propertyValue = IntPtr.Zero;
            try
            {
                WithSetting(settingId, (setting, propertyName) =>
                {
                    ThrowIfFailed(GetDelegate<GetValueDelegate>(setting, 13)(setting, propertyName, out value));
                });
                ThrowIfFailed(QueryInterface(value, PropertyValueIid, out propertyValue));
                int actualType;
                ThrowIfFailed(GetDelegate<GetInt32Delegate>(propertyValue, 6)(propertyValue, out actualType));
                if (actualType != expectedType)
                {
                    throw new InvalidOperationException(
                        $"Taskbar setting '{settingId}' returned property type {actualType}; expected {expectedType}. " +
                        "The undocumented Windows taskbar settings ABI has changed.");
                }
                return read(propertyValue);
            }
            finally
            {
                Release(propertyValue);
                Release(value);
            }
        }

        private static AppBarData CreateTaskbarAppBarData()
        {
            IntPtr taskbar = FindWindow("Shell_TrayWnd", null);
            if (taskbar == IntPtr.Zero)
            {
                throw new InvalidOperationException("Windows Explorer taskbar window was not found.");
            }
            return new AppBarData
            {
                cbSize = checked((uint)Marshal.SizeOf<AppBarData>()),
                hWnd = taskbar
            };
        }

        private static void WriteValue(string settingId, IntPtr value)
        {
            WithSetting(settingId, (setting, propertyName) =>
            {
                ThrowIfFailed(GetDelegate<SetValueDelegate>(setting, 14)(setting, propertyName, value));
            });
        }

        private static void WithSetting(string settingId, Action<IntPtr, IntPtr> action)
        {
            IntPtr settingName = IntPtr.Zero;
            IntPtr propertyName = IntPtr.Zero;
            IntPtr inspectable = IntPtr.Zero;
            IntPtr settingItem = IntPtr.Zero;
            try
            {
                settingName = CreateHString(settingId);
                ThrowIfFailed(GetSetting(settingName, out inspectable));
                if (inspectable == IntPtr.Zero)
                {
                    throw new InvalidOperationException($"Windows did not return taskbar setting '{settingId}'.");
                }
                ThrowIfFailed(QueryInterface(inspectable, SettingItemIid, out settingItem));
                propertyName = CreateHString(ValueProperty);
                action(settingItem, propertyName);
            }
            finally
            {
                Release(settingItem);
                Release(inspectable);
                DeleteHString(propertyName);
                DeleteHString(settingName);
            }
        }

        private static int QueryInterface(IntPtr instance, Guid iid, out IntPtr result)
        {
            return GetDelegate<QueryInterfaceDelegate>(instance, 0)(instance, in iid, out result);
        }

        private static TDelegate GetDelegate<TDelegate>(IntPtr instance, int slot)
            where TDelegate : Delegate
        {
            if (instance == IntPtr.Zero)
            {
                throw new InvalidOperationException("Windows returned a null COM interface.");
            }
            IntPtr vtable = Marshal.ReadIntPtr(instance);
            IntPtr function = Marshal.ReadIntPtr(vtable, slot * IntPtr.Size);
            return Marshal.GetDelegateForFunctionPointer<TDelegate>(function);
        }

        private static IntPtr CreateHString(string value)
        {
            IntPtr result;
            ThrowIfFailed(WindowsCreateString(value, checked((uint)value.Length), out result));
            return result;
        }

        private static void DeleteHString(IntPtr value)
        {
            if (value != IntPtr.Zero)
            {
                ThrowIfFailed(WindowsDeleteString(value));
            }
        }

        private static void Release(IntPtr value)
        {
            if (value != IntPtr.Zero)
            {
                GetDelegate<ReleaseDelegate>(value, 2)(value);
            }
        }

        private static void ThrowIfFailed(int hresult)
        {
            if (hresult < 0)
            {
                Marshal.ThrowExceptionForHR(hresult);
            }
        }
    }
}
