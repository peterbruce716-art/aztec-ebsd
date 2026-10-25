using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;

// Reads populated AZtec objects only. All crystallographic values remain native.
public static class AztecNativeGosPixelAudit {
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    static readonly BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    static object P(object value, string name) {
        if (value == null) return null;
        var type = value.GetType();
        var property = type.GetProperty(name, Flags);
        if (property != null) return property.GetValue(value, null);
        var field = type.GetField(name, Flags);
        if (field != null) return field.GetValue(value);
        throw new MissingMemberException(type.FullName, name);
    }
    static int I(object value) { return Convert.ToInt32(value, Inv); }
    static double D(object value) { return Convert.ToDouble(value, Inv); }
    static string F(double value) { return value.ToString("R", Inv); }
    static int Packed(object rgb) {
        if (rgb == null) return -1;
        return unchecked((int)0xff000000) | I(P(rgb,"R")) << 16 | I(P(rgb,"G")) << 8 | I(P(rgb,"B"));
    }
    static string Rgb(int argb, bool exists) {
        return exists ? ((argb >> 16) & 255)+","+((argb >> 8) & 255)+","+(argb & 255) : ",,";
    }
    static MethodInfo M(object obj, string name, params Type[] types) {
        var method=obj.GetType().GetMethod(name,Flags,null,types,null);
        if(method==null)foreach(var candidate in obj.GetType().GetMethods(Flags)){
            if(candidate.Name!=name)continue;var args=candidate.GetParameters();if(args.Length<types.Length)continue;
            bool matches=true;for(int i=0;i<args.Length;i++){
                if(i<types.Length?args[i].ParameterType!=types[i]:!args[i].IsOptional){matches=false;break;}
            }
            if(matches){method=candidate;break;}
        }
        if(method==null)throw new MissingMethodException(obj.GetType().FullName,name);
        return method;
    }
    static object Call(MethodInfo method,object instance,params object[] values){
        var args=method.GetParameters();var actual=new object[args.Length];
        for(int i=0;i<args.Length;i++)actual[i]=i<values.Length?values[i]:args[i].DefaultValue;
        return method.Invoke(instance,actual);
    }
    public static Dictionary<string, object> Run(object layer, object dataset, object sizing, object boundaries,
        string legacyCsv, string output, double oldMin, double oldMax) {
        int width=I(P(dataset,"XCount")),height=I(P(dataset,"YCount")),count=I(P(dataset,"PixelCount"));
        if(width*height!=count)throw new InvalidOperationException("geometry_mismatch");
        string[] names={"GOS_native_float_pixels.bmp","GOS_native_old_range_pixels.bmp","GOS_csv_automatic_pixels.bmp","GOS_csv_old_range_pixels.bmp","GOS_double_automatic_pixels.bmp","GOS_calibrated_pixels.bmp","point_audit.csv"};
        foreach(string name in names)if(File.Exists(Path.Combine(output,name)))throw new IOException("output_exists:"+name);
        var values=P(layer,"Values");
        var floats=(float[])P(values,"Items");
        var phaseItems=(Array)P(P(dataset,"PhaseID"),"Items");
        var grainMap=P(sizing,"GrainMap");
        var grainIds=(Array)P(grainMap,"Data");
        var grains=new List<object>();
        object grainList=P(sizing,"GrainList");var itemsProperty=grainList.GetType().GetProperty("Items",Flags);
        foreach(object grain in (IEnumerable)(itemsProperty==null?grainList:itemsProperty.GetValue(grainList,null)))grains.Add(grain);
        var right=(Array)P(boundaries,"BoundaryRight");
        var bottom=(Array)P(boundaries,"BoundaryBottom");
        if(floats.Length!=count||phaseItems.Length!=count||grainIds.Length!=count||right.Length!=count||bottom.Length!=count)
            throw new InvalidOperationException("native_array_count_mismatch");
        var csvValues=new double[count];var csvSeen=new bool[count];int csvRows=0;
        using(var reader=new StreamReader(legacyCsv,Encoding.UTF8,true)) {
            if(reader.ReadLine()!="Index,Grain Orientation Spread")throw new InvalidDataException("legacy_header");
            reader.ReadLine();string line;
            while((line=reader.ReadLine())!=null){if(string.IsNullOrWhiteSpace(line))continue;var f=line.Split(',');int index=int.Parse(f[0],Inv);
                if(index<0||index>=count||csvSeen[index])throw new InvalidDataException("legacy_index");
                csvValues[index]=double.Parse(f[1],Inv);csvSeen[index]=true;csvRows++;
            }
        }
        if(csvRows!=count)throw new InvalidDataException("legacy_coverage");
        var limits=P(layer,"LimitsForDrawing");double min=D(P(limits,"Item1")),max=D(P(limits,"Item2"));
        if(!(max>min))throw new InvalidOperationException("native_range_invalid");
        var scale=P(P(layer,"Settings"),"ColorScaleSettings");
        var scaleType=P(scale,"ColorScaleType");var inverted=P(scale,"Inverted");var gradient=P(scale,"WithColorGradient");var steps=P(scale,"StepCount");
        var colorType=layer.GetType().Assembly.GetType("Core.Ebsd.ImageProcessing.ColorCoding",true);
        var colorMethod=colorType.GetMethod("GetColorFromScale",BindingFlags.Static|BindingFlags.Public,null,
            new[]{typeof(double),typeof(double),typeof(double),scaleType.GetType(),typeof(bool),typeof(bool),typeof(int)},null);
        if(colorMethod==null)throw new MissingMethodException("ColorCoding.GetColorFromScale");
        Func<double,double,double,int> color=(v,lo,hi)=>Packed(colorMethod.Invoke(null,new[]{(object)v,lo,hi,scaleType,inverted,gradient,steps}));
        var getPixel=M(layer,"GetPixel",typeof(int));var getValue=M(layer,"GetValue",typeof(int));var valid=M(layer,"IsValid",typeof(int));
        var getIndex=M(values,"GetIndex",typeof(int),typeof(int));
        int[][] images=new int[6][];for(int k=0;k<images.Length;k++)images[k]=new int[count];
        long roundedMismatch=0,floatColorMismatch=0,oldRoundedColorMismatch=0,autoRoundedColorMismatch=0,rangeColorMismatch=0,doubleColorMismatch=0;
        long phase0=0,invalid=0,nullPixels=0,phaseGrainMismatch=0,roundedBeyondLimits=0,validFalse=0;
        double maxCsvDelta=0,maxDoubleDelta=0;var nativeType=floats.GetType().FullName;
        using(var writer=new StreamWriter(Path.Combine(output,"point_audit.csv"),false,new UTF8Encoding(true))) {
            writer.WriteLine("Index,X,Y,GrainId,PhaseId,NativeFloatDegree,GetValueDegree,MeanGosDegree,CsvDegree,Valid,NativeR,NativeG,NativeB,BoundaryRight,BoundaryBottom,InvalidGrain,NativePixelHasValue,OldRangeR,OldRangeG,OldRangeB,CsvOldR,CsvOldG,CsvOldB,CsvAutomaticR,CsvAutomaticG,CsvAutomaticB,ColorPosition,NativeMin,NativeMax,GrainPhaseId");
            for(int index=0;index<count;index++) {
                int x=index%width,y=index/width;
                if(I(Call(getIndex,values,x,y))!=index)throw new InvalidOperationException("record_index_not_x_fastest:"+index);
                int gid=I(grainIds.GetValue(index)),phase=I(phaseItems.GetValue(index));
                object grain=gid>0&&gid<=grains.Count?grains[gid-1]:null;
                object meanRad=P(grain,"GrainOrientationSpreadRad");
                bool invalidGrain=grain==null||meanRad==null;
                int grainPhase=grain==null?-1:I(P(grain,"PhaseID"));
                if(grainPhase!=phase)phaseGrainMismatch++;
                double mean=meanRad==null?double.NaN:D(meanRad)*(180.0/Math.PI);
                double v=floats[index];object gotValue=getValue.Invoke(layer,new object[]{index});
                if(gotValue==null||D(gotValue)!=v)throw new InvalidOperationException("getvalue_float_mismatch:"+index);
                bool isValid=(bool)valid.Invoke(layer,new object[]{index});if(!isValid)validFalse++;
                object rgb=getPixel.Invoke(layer,new object[]{index});int native=Packed(rgb);
                if(rgb==null)nullPixels++;
                if(phase==0)phase0++;if(invalidGrain)invalid++;
                bool inRange=v>=min&&v<=max;
                int direct=inRange?color(v,min,max):-1;
                if(native!=direct)floatColorMismatch++;
                int old=color(v,oldMin,oldMax),csvOld=color(csvValues[index],oldMin,oldMax),csvAuto=color(csvValues[index],min,max);
                int doubleAuto=double.IsNaN(mean)?-1:color(mean,min,max);
                if(csvValues[index]<min||csvValues[index]>max)roundedBeyondLimits++;
                if(csvValues[index]!=v)roundedMismatch++;
                if(old!=csvOld)oldRoundedColorMismatch++;
                if(native!=csvAuto)autoRoundedColorMismatch++;
                if(native!=old)rangeColorMismatch++;
                if(native!=doubleAuto&&phase>0&&!invalidGrain)doubleColorMismatch++;
                maxCsvDelta=Math.Max(maxCsvDelta,Math.Abs(v-csvValues[index]));
                if(!double.IsNaN(mean)&&phase>0)maxDoubleDelta=Math.Max(maxDoubleDelta,Math.Abs(v-mean));
                images[0][index]=native;images[1][index]=old;images[2][index]=csvAuto;images[3][index]=csvOld;images[4][index]=doubleAuto;
                images[5][index]=phase==0||invalidGrain||rgb==null?-1:native;
                writer.WriteLine(index+","+x+","+y+","+gid+","+phase+","+F(v)+","+F(D(gotValue))+","+(double.IsNaN(mean)?"":F(mean))+","+F(csvValues[index])+","+(isValid?1:0)+","+
                    Rgb(native,rgb!=null)+","+I(right.GetValue(index))+","+I(bottom.GetValue(index))+","+(invalidGrain?1:0)+","+(rgb!=null?1:0)+","+
                    Rgb(old,true)+","+Rgb(csvOld,true)+","+Rgb(csvAuto,true)+","+F((v-min)/(max-min))+","+F(min)+","+F(max)+","+grainPhase);
            }
        }
        if(floatColorMismatch!=0)throw new InvalidOperationException("native_getpixel_direct_color_mismatch:"+floatColorMismatch);
        var bitmapType=layer.GetType().Assembly.GetType("Core.Ebsd.ImageProcessing.BitmapTools",true);
        var toBitmap=bitmapType.GetMethod("IntArrayToBitmap",new[]{typeof(int[]),typeof(int),typeof(int)});
        MethodInfo save=null;
        if(toBitmap!=null)foreach(var method in bitmapType.GetMethods(BindingFlags.Static|BindingFlags.Public)){
            var args=method.GetParameters();if(method.Name=="Save"&&args.Length==2&&args[0].ParameterType.IsAssignableFrom(toBitmap.ReturnType)&&args[1].ParameterType==typeof(string)){save=method;break;}
        }
        if(toBitmap==null||save==null)throw new MissingMethodException("BitmapTools encode");
        for(int k=0;k<images.Length;k++){
            object bmp=toBitmap.Invoke(null,new object[]{images[k],width,height});
            try{save.Invoke(null,new object[]{bmp,Path.Combine(output,names[k])});}finally{var disposable=bmp as IDisposable;if(disposable!=null)disposable.Dispose();}
        }
        return new Dictionary<string,object>{
            {"point_count",count},{"grain_count",grains.Count},{"phase0_count",phase0},{"invalid_grain_count",invalid},{"null_getpixel_count",nullPixels},
            {"native_tuple_invalid_count",validFalse},{"phase_grain_mismatch_count",phaseGrainMismatch},{"getvalue_float_mismatch_count",0},
            {"getpixel_direct_color_mismatch_count",floatColorMismatch},{"csv_float_different_value_count",roundedMismatch},
            {"csv_old_range_color_difference_count",oldRoundedColorMismatch},{"csv_automatic_color_difference_count",autoRoundedColorMismatch},
            {"native_vs_old_range_color_difference_count",rangeColorMismatch},{"native_vs_grain_double_color_difference_count",doubleColorMismatch},
            {"csv_beyond_actual_limits_count",roundedBeyondLimits},{"max_csv_float_absolute_delta_degree",maxCsvDelta},
            {"max_grain_double_float_absolute_delta_degree",maxDoubleDelta},{"float_array_type",nativeType}
        };
    }
}
