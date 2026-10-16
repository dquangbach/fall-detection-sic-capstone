from .tikzeng import *

def block_2Conv_pool(name, botton, top, s_filer=256, n_filer=(64,64), offset="(1,0,0)", size=(32,32,3.5), opacity=0.5):
    return [
        to_ConvConvRelu(
            name="ccr_"+name,
            s_filer=str(s_filer),
            n_filer=n_filer,
            offset=offset,
            to="("+botton+"-east)",
            width=(size[2],size[2]),
            height=size[0],
            depth=size[1],
        ),    
        to_Pool(
            name=top,
            offset="(0,0,0)",
            to="(ccr_"+name+"-east)",
            width=1,
            height=size[0] - int(size[0]*0.2),
            depth=size[1] - int(size[1]*0.2),
            opacity=opacity,
        ),
        to_connection(botton, "ccr_"+name)
    ]

def block_Conv_pool(name, botton, top, s_filer=256, n_filer=64, offset="(1.5,0,0)", size=(32,32,3.5), opacity=0.5, caption=""):
    return [
        to_ConvRelu(
            name="cr_"+name,
            s_filer=str(s_filer),
            n_filer=n_filer,
            offset=offset,
            to="("+botton+"-east)",
            width=size[2],
            height=size[0],
            depth=size[1],
            caption=caption
        ),    
        to_Pool(
            name=top,
            offset="(0,0,0)",
            to="(cr_"+name+"-east)",
            width=1.5,
            height=size[0] - int(size[0]*0.25),
            depth=size[1] - int(size[1]*0.25),
            opacity=opacity,
        ),
        to_connection(botton, "cr_"+name)
    ]

