/*
ShaderGlass: shader effect overlay
Copyright (C) 2021-2025 mausimus (mausimus.net)
https://github.com/mausimus/ShaderGlass
GNU General Public License v3.0
*/

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
    void setClickThrough(bool enabled);

private:
    void* nsWindow;
    void* mtkView;
};
