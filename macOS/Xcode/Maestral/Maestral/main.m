//
//  main.m
//  A main module for starting Python projects on macOS.
//
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Cocoa/Cocoa.h>
#include <Python.h>
#include <dlfcn.h>

#ifndef DEBUG
    #define NSLog(...);
#endif

void crash_dialog(NSString *);

int main(int argc, char *argv[]) {
    int ret = 0;
    unsigned int i;
    NSString *module_name;
    NSString *python_home;
    NSString *python_path;
    wchar_t *wpython_home;
    const char* nslog_script;
    wchar_t** python_argv;
    PyObject *module;
    PyObject *runpy;
    PyObject *runmodule;
    PyObject *runargs;
    PyObject *result;
    PyObject *sys;
    PyObject *traceback;

    @autoreleasepool {

        NSString * resourcePath = [[NSBundle mainBundle] resourcePath];

        // Special environment to prefer .pyo; also, dont write bytecode
        // because the process will not have write permissions on the device.
        putenv("PYTHONDONTWRITEBYTECODE=1");
        putenv("PYTHONUNBUFFERED=1");

        // Set the home for the Python interpreter
        python_home = [NSString stringWithFormat:@"%@/Support/Python/Resources", resourcePath, nil];
        NSLog(@"PythonHome is: %@", python_home);
        wpython_home = Py_DecodeLocale([python_home UTF8String], NULL);
        Py_SetPythonHome(wpython_home);

        // Set the PYTHONPATH
        python_path = [NSString stringWithFormat:@"PYTHONPATH=%@/app:%@/app_packages", resourcePath, resourcePath, nil];
        NSLog(@"PYTHONPATH is: %@", python_path);
        putenv((char *)[python_path UTF8String]);

        NSLog(@"Initializing Python runtime...");
        Py_Initialize();

        // Set the name of the python NSLog bootstrap script
        nslog_script = [
            [[NSBundle mainBundle] pathForResource:@"app_packages/nslog"
                                            ofType:@"py"] cStringUsingEncoding:NSUTF8StringEncoding];

        if (nslog_script == NULL) {
            NSLog(@"Unable to locate NSLog bootstrap script.");
            crash_dialog(@"Unable to locate NSLog bootstrap script.");
            exit(-2);
        }

        // Construct argv for the interpreter
        python_argv = PyMem_RawMalloc(sizeof(wchar_t*) * argc);

        module_name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MainModule"];
        python_argv[0] = Py_DecodeLocale([module_name UTF8String], NULL);
        for (i = 1; i < argc; i++) {
            python_argv[i] = Py_DecodeLocale(argv[i], NULL);
        }

        PySys_SetArgv(argc, python_argv);

        @try {
            NSLog(@"Installing Python NSLog handler...");
            FILE* fd = fopen(nslog_script, "r");
            if (fd == NULL) {
                NSLog(@"Unable to open nslog.py; abort.");
                crash_dialog(@"Unable to open nslog.py");
                exit(-1);
            }

            ret = PyRun_SimpleFileEx(fd, nslog_script, 1);
            fclose(fd);
            if (ret != 0) {
                NSLog(@"Unable to install Python NSLog handler; abort.");
                crash_dialog(@"Unable to install Python NSLog handler.");
                exit(ret);
            }

            // Start the app module
            NSLog(@"Running app module: %@", module_name);
            runpy = PyImport_ImportModule("runpy");
            if (runpy == NULL) {
                NSLog(@"Could not import runpy module");
                crash_dialog(@"Could not import runpy module");
                exit(-2);
            }

            runmodule = PyObject_GetAttrString(runpy, "_run_module_as_main");
            if (runmodule == NULL) {
                NSLog(@"Could not access runpy._run_module_as_main");
                crash_dialog(@"Could not access runpy._run_module_as_main");
                exit(-3);
            }

            module = PyUnicode_FromWideChar(python_argv[0], wcslen(python_argv[0]));
            if (module == NULL) {
                NSLog(@"Could not convert module name to unicode");
                crash_dialog(@"Could not convert module name to unicode");
                exit(-3);
            }

            runargs = Py_BuildValue("(Oi)", module, 0);
            if (runargs == NULL) {
                NSLog(@"Could not create arguments for runpy._run_module_as_main");
                crash_dialog(@"Could not create arguments for runpy._run_module_as_main");
                exit(-4);
            }

            result = PyObject_Call(runmodule, runargs, NULL);
            if (result == NULL) {
                NSLog(@"Application quit abnormally!");

                // Output the current error state of the interpreter.
                // This will trigger out custom sys.excepthook
                PyErr_Print();

                // Retrieve sys._traceback
                sys = PyImport_ImportModule("sys");
                if (runpy == NULL) {
                    NSLog(@"Could not import sys module");
                    crash_dialog(@"Could not import sys module");
                    exit(-5);
                }

                traceback = PyObject_GetAttrString(sys, "_traceback");
                if (traceback == NULL) {
                    NSLog(@"Could not access sys._traceback");
                    crash_dialog(@"Could not access sys._traceback");
                    exit(-6);
                }

                // Display stack trace in the crash dialog.
                crash_dialog([NSString stringWithUTF8String:PyUnicode_AsUTF8(PyObject_Str(traceback))]);
                exit(-7);
            }

        }
        @catch (NSException *exception) {
            NSLog(@"Python runtime error: %@", [exception reason]);
            crash_dialog([NSString stringWithFormat:@"Python runtime error: %@", [exception reason]]);
        }
        @finally {
            Py_Finalize();
        }

        PyMem_RawFree(wpython_home);
        if (python_argv) {
            for (i = 0; i < argc; i++) {
                PyMem_RawFree(python_argv[i]);
            }
            PyMem_RawFree(python_argv);
        }
        NSLog(@"Leaving...");
    }

    exit(ret);
    return ret;
}


void crash_dialog(NSString *details) {
    // We've crashed.
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];

    // Create a stack trace dialog
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setAlertStyle:NSAlertStyleCritical];
    [alert setMessageText:@"Application has crashed"];
    [alert setInformativeText:@"An unexpected error occurred. Please see the traceback below for more information."];

    // A multiline text widget in a scroll view to contain the stack trace
    NSScrollView *scroll_panel = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 600, 300)];
    [scroll_panel setHasVerticalScroller:true];
    [scroll_panel setHasHorizontalScroller:false];
    [scroll_panel setAutohidesScrollers:false];
    [scroll_panel setBorderType:NSBezelBorder];

    NSTextView *crash_text = [[NSTextView alloc] init];
    [crash_text setEditable:false];
    [crash_text setSelectable:true];
    [crash_text setString:details];
    [crash_text setVerticallyResizable:true];
    [crash_text setHorizontallyResizable:true];
    [crash_text setFont:[NSFont fontWithName:@"Menlo" size:12.0]];

    [scroll_panel setDocumentView:crash_text];
    [alert setAccessoryView:scroll_panel];

    // Show the crash dialog
    [alert runModal];
}
