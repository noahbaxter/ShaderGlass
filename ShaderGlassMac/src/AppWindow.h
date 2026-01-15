#pragma once

class AppWindow {
public:
    AppWindow();
    ~AppWindow();

    bool create(int width, int height, const char* title);
    void show();
    void close();

    void* getNSWindow();
    void* getMTKView();

private:
    void* nsWindow;
    void* mtkView;
};
