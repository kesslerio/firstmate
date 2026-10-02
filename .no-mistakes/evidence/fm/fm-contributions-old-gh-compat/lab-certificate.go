package main
import("crypto/rand";"crypto/rsa";"crypto/x509";"crypto/x509/pkix";"encoding/pem";"math/big";"os";"time")
func main(){
 key,e:=rsa.GenerateKey(rand.Reader,2048);if e!=nil{panic(e)}
 cert:=&x509.Certificate{SerialNumber:big.NewInt(1),Subject:pkix.Name{CommonName:"api.github.com"},DNSNames:[]string{"api.github.com","github.com"},NotBefore:time.Now().Add(-time.Minute),NotAfter:time.Now().Add(time.Hour),KeyUsage:x509.KeyUsageDigitalSignature|x509.KeyUsageCertSign,ExtKeyUsage:[]x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},BasicConstraintsValid:true,IsCA:true}
 data,e:=x509.CreateCertificate(rand.Reader,cert,cert,&key.PublicKey,key);if e!=nil{panic(e)}
 if e=os.WriteFile(".test-scratch/live-tools/server.crt",pem.EncodeToMemory(&pem.Block{Type:"CERTIFICATE",Bytes:data}),0600);e!=nil{panic(e)}
 if e=os.WriteFile(".test-scratch/live-tools/server.key",pem.EncodeToMemory(&pem.Block{Type:"RSA PRIVATE KEY",Bytes:x509.MarshalPKCS1PrivateKey(key)}),0600);e!=nil{panic(e)}
}
