using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;

public static class NativeBcAudit {
    static readonly CultureInfo Inv=CultureInfo.InvariantCulture;
    static readonly BindingFlags Flags=BindingFlags.Instance|BindingFlags.Public;
    static object P(object v,string n){var p=v.GetType().GetProperty(n,Flags);if(p==null)throw new MissingMemberException(v.GetType().FullName,n);return p.GetValue(v,null);}
    static int I(object v){return Convert.ToInt32(v,Inv);}
    static MethodInfo IndexMethod(object values){foreach(var m in values.GetType().GetMethods(Flags)){if(m.Name!="GetIndex")continue;var a=m.GetParameters();if(a.Length<2||a[0].ParameterType!=typeof(int)||a[1].ParameterType!=typeof(int))continue;bool ok=true;for(int i=2;i<a.Length;i++)if(!a[i].IsOptional)ok=false;if(ok)return m;}throw new MissingMethodException("GetIndex(int,int,optional...)");}
    public static Dictionary<string,object> Run(object dataset,object layer,string path){
        int width=I(P(dataset,"XCount")),height=I(P(dataset,"YCount")),count=I(P(dataset,"PixelCount"));
        if(width*height!=count)throw new InvalidOperationException("geometry_mismatch");
        var bc=P(dataset,"BandContrast");var phase=P(dataset,"PhaseID");var values=P(layer,"Values");
        var bytes=(Array)P(bc,"Items");var phases=(Array)P(phase,"Items");var layerItems=(Array)P(values,"Items");
        if(bytes.Length!=count||phases.Length!=count||layerItems.Length!=count)throw new InvalidOperationException("data_count_mismatch");
        var indexMethod=IndexMethod(bc);var indexArgs=new object[indexMethod.GetParameters().Length];
        for(int i=2;i<indexArgs.Length;i++)indexArgs[i]=indexMethod.GetParameters()[i].DefaultValue;
        var pixelMethod=layer.GetType().GetMethod("GetPixel",new[]{typeof(int)});var validMethod=layer.GetType().GetMethod("IsValid",new[]{typeof(int)});
        var limits=P(layer,"LimitsForDrawing");double min=Convert.ToDouble(P(limits,"Item1"),Inv),max=Convert.ToDouble(P(limits,"Item2"),Inv);
        var scale=P(P(layer,"Settings"),"ColorScaleSettings");var kind=P(scale,"ColorScaleType");
        var colorType=layer.GetType().Assembly.GetType("Core.Ebsd.ImageProcessing.ColorCoding",true);
        var colorMethod=colorType.GetMethod("GetColorFromScale",BindingFlags.Static|BindingFlags.Public,null,new[]{typeof(double),typeof(double),typeof(double),kind.GetType(),typeof(bool),typeof(bool),typeof(int)},null);
        int rawMin=255,rawMax=0,phaseZero=0,nullPixels=0,invalid=0,notGray=0,colorMismatch=0;var histogram=new int[256];var gray=new SortedDictionary<int,string>();var samples=new List<object>();
        using(var stream=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None))using(var writer=new StreamWriter(stream,new UTF8Encoding(true))){
            writer.WriteLine("Index,BandContrast,PhaseId,X,Y,NativeR,NativeG,NativeB,NativePixelHasValue,NativeIsValid");
            for(int index=0;index<count;index++){
                int x=index%width,y=index/width;indexArgs[0]=x;indexArgs[1]=y;
                if(I(indexMethod.Invoke(bc,indexArgs))!=index)throw new InvalidOperationException("record_index_not_x_fastest:"+index);
                int b=I(bytes.GetValue(index)),p=I(phases.GetValue(index));
                if(I(layerItems.GetValue(index))!=b)throw new InvalidOperationException("native_layer_values_mismatch:"+index);
                rawMin=Math.Min(rawMin,b);rawMax=Math.Max(rawMax,b);histogram[b]++;if(p==0)phaseZero++;
                object rgb=pixelMethod.Invoke(layer,new object[]{index});bool isValid=(bool)validMethod.Invoke(layer,new object[]{index});if(!isValid)invalid++;
                string c=",,";
                if(rgb==null)nullPixels++;else{
                    int r=I(P(rgb,"R")),g=I(P(rgb,"G")),bl=I(P(rgb,"B"));c=r+","+g+","+bl;if(r!=g||g!=bl)notGray++;
                    string previous;if(gray.TryGetValue(b,out previous)&&previous!=c)throw new InvalidOperationException("bc_same_value_different_color");gray[b]=c;
                    if(colorMethod!=null){object direct=colorMethod.Invoke(null,new[]{(object)(double)b,min,max,kind,P(scale,"Inverted"),P(scale,"WithColorGradient"),P(scale,"StepCount")});if(I(P(direct,"R"))!=r||I(P(direct,"G"))!=g||I(P(direct,"B"))!=bl)colorMismatch++;}
                }
                writer.WriteLine(index+","+b+","+p+","+x+","+y+","+c+","+(rgb==null?"0":"1")+","+(isValid?"1":"0"));
                if(p==0||index==0||index==count-1)samples.Add(new Dictionary<string,object>{{"index",index},{"band_contrast",b},{"phase_id",p},{"rgb",rgb==null?null:c},{"is_valid",isValid}});
            }
        }
        var grayRows=new List<object>();foreach(var kv in gray)grayRows.Add(new Dictionary<string,object>{{"band_contrast",kv.Key},{"rgb",kv.Value}});
        return new Dictionary<string,object>{{"count",count},{"raw_range",new[]{rawMin,rawMax}},{"histogram_0_255",histogram},{"phase_zero_count",phaseZero},{"native_null_pixel_count",nullPixels},{"native_isvalid_false_count",invalid},{"native_non_gray_count",notGray},{"native_colorcoding_mismatch_count",colorMismatch},{"colorcoding_comparison_available",colorMethod!=null},{"native_gray_lookup",grayRows},{"selected_samples",samples},{"index_verified_count",count},{"native_layer_value_equal_count",count},{"index_method",indexMethod.ToString()}};
    }
}
